
const http = require('http');
const { WebSocketServer } = require('ws');
const crypto = require('crypto');

const port = Number(process.env.PORT || 8080);
const server = http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('Worm Arena multiplayer server is running.\n');
});
const wss = new WebSocketServer({ server, perMessageDeflate: false });
const rooms = new Map();

const VALID_MINUTES = [5, 7, 10];
const MAX_PLAYERS = 8;
const FOOD_COUNT = 45;
const TICK_MS = 50;           // 20 simulation steps per second
const BROADCAST_EVERY = 1;    // 20 state updates per second for smoother remote movement
const SPEED = 0.16;           // normalized arena units / second
const TRAIL_SPACING = 0.010;
const FOOD_RADIUS = 0.027;
const COLLISION_RADIUS = 0.014;
const MAX_TRAIL_POINTS = 160;
const WORLD_H = 9 / 16;       // arena is 1.0 wide x 0.5625 tall (16:9); client letterboxes to match
const r4 = n => Math.round(n * 10000) / 10000;

function roomCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return Array.from({ length: 6 }, () => chars[crypto.randomInt(chars.length)]).join('');
}
function rand() { return 0.08 + Math.random() * 0.84; }
function randY() { return WORLD_H * (0.08 + Math.random() * 0.84); }
function foodItem() { return { id: crypto.randomUUID(), x: r4(rand()), y: r4(randY()) }; }
function send(ws, obj) {
  if (ws.readyState === 1) ws.send(JSON.stringify(obj));
}
function distance(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }

function publicState(room) {
  const now = Date.now();
  return {
    type: 'state',
    roomCode: room.code,
    minutes: room.minutes,
    started: room.started,
    secondsLeft: room.started ? Math.max(0, Math.ceil((room.endsAt - now) / 1000)) : 0,
    players: [...room.players.values()].map(p => ({
      id: p.id, name: p.name, host: p.id === room.hostId,
      score: p.score, length: p.trail.length, alive: p.alive
    })),
    worldH: WORLD_H,
    worms: Object.fromEntries([...room.players.values()].map(p => [p.id, {
      trail: p.trail.map(t => ({ x: r4(t.x), y: r4(t.y) })), alive: p.alive, score: p.score, name: p.name
    }])),
    food: room.food
  };
}
function broadcast(room) {
  if (!room.players.size) return;
  const data = JSON.stringify(publicState(room));
  for (const p of room.players.values()) {
    if (p.ws.readyState === 1) p.ws.send(data);
  }
}
function finish(room) {
  room.started = false;
  if (room.interval) clearInterval(room.interval);
  room.interval = null;
  const ranking = [...room.players.values()]
    .sort((a, b) => b.score - a.score)
    .map((p, i) => ({ rank: i + 1, id: p.id, name: p.name, score: p.score, length: p.trail.length }));
  for (const p of room.players.values()) send(p.ws, { type: 'ended', roomCode: room.code, ranking });
  broadcast(room);
}
function removePlayer(ws) {
  const room = rooms.get(ws.roomCode);
  if (!room) return;
  room.players.delete(ws.playerId);
  if (!room.players.size) {
    if (room.interval) clearInterval(room.interval);
    rooms.delete(room.code);
  } else {
    if (room.hostId === ws.playerId) room.hostId = room.players.keys().next().value;
    broadcast(room);
  }
}
function spawnTrail() {
  const x = rand(), y = randY();
  return Array.from({ length: 10 }, (_, i) => ({ x: Math.max(0.02, x - i * TRAIL_SPACING), y }));
}
function respawn(p) {
  p.alive = true;
  p.dir = { x: 1, y: 0 };
  p.score = Math.max(0, p.score - 2);
  p.trail = spawnTrail();
  p.head = { x: p.trail[0].x, y: p.trail[0].y };
  p.growth = 0;
}
function pointSegmentDistance(point, a, b) {
  const vx = b.x - a.x, vy = b.y - a.y;
  const denom = vx * vx + vy * vy;
  if (denom === 0) return distance(point, a);
  const t = Math.max(0, Math.min(1, ((point.x - a.x) * vx + (point.y - a.y) * vy) / denom));
  return Math.hypot(point.x - (a.x + t * vx), point.y - (a.y + t * vy));
}
function addTrailPoint(p, point) {
  // trail[0] is always the live head; a new fixed body point is added each time
  // the head has moved TRAIL_SPACING away from the previous body point.
  if (p.trail.length < 2 || distance(p.trail[1], point) >= TRAIL_SPACING) {
    p.trail.unshift({ x: point.x, y: point.y });
  } else {
    p.trail[0] = { x: point.x, y: point.y };
  }
  const desired = Math.min(MAX_TRAIL_POINTS, 10 + p.score * 3);
  while (p.trail.length > desired) p.trail.pop();
}
function collectFood(room, p, oldHead, newHead) {
  for (let i = room.food.length - 1; i >= 0; i--) {
    const f = room.food[i];
    // Swept collision: count a pellet if the head's path passes near it,
    // not only when a discrete update lands directly on the pellet.
    if (pointSegmentDistance(f, oldHead, newHead) <= FOOD_RADIUS) {
      room.food.splice(i, 1);
      p.score += 1;
      p.growth = Math.min(100, p.growth + 3);
      room.food.push(foodItem());
    }
  }
}
function simulationStep(room) {
  if (!room.started) return;
  const dt = TICK_MS / 1000;
  const previousHeads = new Map();

  // Move continuously based on each player's most recent steering direction.
  for (const p of room.players.values()) {
    if (!p.alive || !p.trail.length) continue;
    const old = p.head || p.trail[0];
    previousHeads.set(p.id, { x: old.x, y: old.y });
    const nx = Math.max(0.015, Math.min(0.985, old.x + p.dir.x * SPEED * dt));
    const ny = Math.max(0.015, Math.min(WORLD_H - 0.015, old.y + p.dir.y * SPEED * dt));
    const next = { x: nx, y: ny };
    collectFood(room, p, old, next);
    addTrailPoint(p, next);
    p.head = next;
  }

  // Basic head-to-body collisions, excluding a short section behind each head.
  const dead = [];
  for (const p of room.players.values()) {
    if (!p.alive || !p.head) continue;
    for (const other of room.players.values()) {
      if (!other.alive) continue;
      const trail = other.trail;
      const start = other.id === p.id ? 8 : 3;
      for (let j = start; j < trail.length; j++) {
        if (distance(p.head, trail[j]) < COLLISION_RADIUS) {
          dead.push(p);
          break;
        }
      }
      if (dead.includes(p)) break;
    }
  }
  for (const p of dead) {
    if (!p.alive) continue;
    p.alive = false;
    p.score = Math.max(0, p.score - 3);
    setTimeout(() => {
      if (rooms.get(room.code) === room && room.started && room.players.has(p.id)) {
        respawn(p);
        broadcast(room);
      }
    }, 1200);
  }
  room.tickCount++;
  if (room.tickCount % BROADCAST_EVERY === 0) broadcast(room);
}
wss.on('connection', ws => {
  ws.on('message', raw => {
    let m;
    try { m = JSON.parse(raw.toString()); }
    catch { return send(ws, { type: 'error', message: 'Invalid message' }); }

    if (m.type === 'create') {
      if (ws.roomCode) removePlayer(ws);
      let code = roomCode();
      while (rooms.has(code)) code = roomCode();
      const minutes = VALID_MINUTES.includes(Number(m.minutes)) ? Number(m.minutes) : 5;
      const room = {
        code, minutes, started: false, endsAt: 0, hostId: String(m.playerId),
        players: new Map(), food: Array.from({ length: FOOD_COUNT }, foodItem),
        interval: null, tickCount: 0
      };
      rooms.set(code, room);
      addPlayer(ws, room, m);
      return;
    }
    if (m.type === 'join') {
      const room = rooms.get(String(m.roomCode || '').toUpperCase());
      if (!room) return send(ws, { type: 'error', message: 'Room not found' });
      if (room.started) return send(ws, { type: 'error', message: 'Match already started' });
      if (room.players.size >= MAX_PLAYERS) return send(ws, { type: 'error', message: 'Room is full (8 players maximum)' });
      addPlayer(ws, room, m);
      return;
    }

    const room = rooms.get(ws.roomCode);
    if (!room || !room.players.has(ws.playerId)) return;
    if (m.type === 'start') {
      if (String(m.playerId) !== room.hostId) return send(ws, { type: 'error', message: 'Only the host can start' });
      if (room.players.size < 2) return send(ws, { type: 'error', message: 'At least 2 players are required' });
      for (const q of room.players.values()) {
        q.score = 0; q.alive = true; q.growth = 0; q.trail = spawnTrail();
        q.head = { x: q.trail[0].x, y: q.trail[0].y }; q.dir = { x: 1, y: 0 };
      }
      room.food = Array.from({ length: FOOD_COUNT }, foodItem);
      room.started = true;
      room.endsAt = Date.now() + room.minutes * 60 * 1000;
      room.tickCount = 0;
      if (room.interval) clearInterval(room.interval);
      room.interval = setInterval(() => {
        if (Date.now() >= room.endsAt) finish(room);
        else simulationStep(room);
      }, TICK_MS);
      broadcast(room);
    } else if (m.type === 'steer' && room.started) {
      const p = room.players.get(ws.playerId);
      if (!p || !p.alive) return;
      let dx = Number(m.dx) || 0;
      let dy = Number(m.dy) || 0;
      const magnitude = Math.hypot(dx, dy);
      if (magnitude > 0.001) {
        dx /= magnitude;
        dy /= magnitude;
        // Ignore near-zero touch noise and preserve last direction on lift.
        p.dir = { x: dx, y: dy };
      }
    }
  });
  ws.on('close', () => removePlayer(ws));
  ws.on('error', () => removePlayer(ws));
});
function addPlayer(ws, room, m) {
  const id = String(m.playerId || crypto.randomUUID());
  ws.playerId = id;
  ws.roomCode = room.code;
  const trail = spawnTrail();
  room.players.set(id, {
    id, name: String(m.name || 'Player').slice(0, 20), ws,
    score: 0, alive: true, growth: 0, trail,
    head: { x: trail[0].x, y: trail[0].y },
    dir: { x: 1, y: 0 }
  });
  send(ws, { type: 'joined', roomCode: room.code });
  broadcast(room);
}
server.listen(port, '0.0.0.0', () => console.log(`Worm Arena server listening on ${port}`));
