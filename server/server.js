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

// ---- Tunables ---------------------------------------------------------
const VALID_MINUTES = [5, 7, 10];
const MAX_PLAYERS = 8;
const MIN_PLAYERS = 2;
const WORLD_W = 3.0;                 // arena is 3.0 x 1.6875 (16:9) -> 9x the old area
const WORLD_H = WORLD_W * 9 / 16;    // the phone shows a ~1.0-wide window that follows your worm
const FOOD_COUNT = 200;
const TICK_MS = 50;                  // 20 simulation steps per second
const SPEED = 0.16;                  // world units / second
const TURN_RATE = 2.6;               // radians / second (~150 deg/s). LOWER = less sensitive steering
const TRAIL_SPACING = 0.010;
const START_LENGTH = 12;
const MAX_TRAIL_POINTS = 200;
const FOOD_RADIUS = 0.027;
const COLLISION_RADIUS = 0.016;
const WALL = 0.02;
// -----------------------------------------------------------------------

const r3 = n => Math.round(n * 1000) / 1000;
function roomCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return Array.from({ length: 6 }, () => chars[crypto.randomInt(chars.length)]).join('');
}
const randX = () => 0.1 + Math.random() * (WORLD_W - 0.2);
const randY = () => 0.1 + Math.random() * (WORLD_H - 0.2);
function send(ws, obj) { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); }
function distance(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }
function pointSegmentDistance(point, a, b) {
  const vx = b.x - a.x, vy = b.y - a.y;
  const denom = vx * vx + vy * vy;
  if (denom === 0) return distance(point, a);
  const t = Math.max(0, Math.min(1, ((point.x - a.x) * vx + (point.y - a.y) * vy) / denom));
  return Math.hypot(point.x - (a.x + t * vx), point.y - (a.y + t * vy));
}
function newFood(room) {
  const f = Array.from({ length: FOOD_COUNT }, () => ({ x: r3(randX()), y: r3(randY()) }));
  room.food = f; room.foodDirty = true;
}
function pickColor(room) {
  const used = new Set([...room.players.values()].map(p => p.color));
  for (let i = 0; i < MAX_PLAYERS; i++) if (!used.has(i)) return i;
  return 0;
}

// Flat arrays keep messages small: [x0,y0,x1,y1,...]
function flat(trail) {
  const out = new Array(trail.length * 2);
  for (let i = 0; i < trail.length; i++) { out[2 * i] = r3(trail[i].x); out[2 * i + 1] = r3(trail[i].y); }
  return out;
}
function publicState(room, withFood) {
  const msg = {
    type: 'state',
    roomCode: room.code,
    minutes: room.minutes,
    started: room.started,
    secondsLeft: room.started ? Math.max(0, Math.ceil((room.endsAt - Date.now()) / 1000)) : 0,
    worldW: WORLD_W, worldH: WORLD_H,
    players: [...room.players.values()].map(p => ({
      id: p.id, name: p.name, host: p.id === room.hostId,
      score: p.score, length: p.trail.length, alive: p.alive, color: p.color
    })),
    worms: Object.fromEntries([...room.players.values()].map(p => [p.id, {
      trail: p.alive ? flat(p.trail) : [], alive: p.alive, color: p.color, name: p.name
    }]))
  };
  if (withFood) msg.food = room.food.flatMap(f => [f.x, f.y]);
  return msg;
}
function broadcast(room, forceFood = false) {
  if (!room.players.size) return;
  const withFood = forceFood || room.foodDirty || room.tickCount % 20 === 0;
  const data = JSON.stringify(publicState(room, withFood));
  room.foodDirty = false;
  for (const p of room.players.values()) if (p.ws.readyState === 1) p.ws.send(data);
}

function ranking(room) {
  return [...room.players.values()]
    .sort((a, b) => {
      if (a.alive !== b.alive) return a.alive ? -1 : 1;     // survivors first
      if (a.alive) return b.score - a.score;                // both alive (time ran out): score
      if (b.elimTick !== a.elimTick) return b.elimTick - a.elimTick; // outlasted others
      return b.score - a.score;
    })
    .map((p, i) => ({ rank: i + 1, id: p.id, name: p.name, score: p.score, length: p.trail.length, alive: p.alive, color: p.color }));
}
function finish(room, reason) {
  if (!room.started) return;
  room.started = false;
  if (room.interval) clearInterval(room.interval);
  room.interval = null;
  const r = ranking(room);
  for (const p of room.players.values()) send(p.ws, { type: 'ended', roomCode: room.code, reason, winnerId: r[0] ? r[0].id : null, ranking: r });
  broadcast(room, true);
}
// Last worm standing wins. Returns true if the match ended.
function checkLastAlive(room) {
  if (!room.started) return false;
  const alive = [...room.players.values()].filter(p => p.alive);
  if (alive.length <= 1) { finish(room, alive.length === 1 ? 'last_alive' : 'draw'); return true; }
  return false;
}
function removePlayer(ws) {
  const room = rooms.get(ws.roomCode);
  if (!room) return;
  room.players.delete(ws.playerId);
  ws.roomCode = null;
  if (!room.players.size) {
    if (room.interval) clearInterval(room.interval);
    rooms.delete(room.code);
    return;
  }
  if (room.hostId === ws.playerId) room.hostId = room.players.keys().next().value;
  if (checkLastAlive(room)) return;
  broadcast(room, true);
}

function spawn(room, p) {
  let x = WORLD_W / 2, y = WORLD_H / 2;
  for (let tries = 0; tries < 60; tries++) {
    x = 0.3 + Math.random() * (WORLD_W - 0.6);
    y = 0.3 + Math.random() * (WORLD_H - 0.6);
    let ok = true;
    for (const o of room.players.values()) {
      if (o === p || !o.trail.length) continue;
      for (let i = 0; i < o.trail.length; i += 4) if (Math.hypot(o.trail[i].x - x, o.trail[i].y - y) < 0.3) { ok = false; break; }
      if (!ok) break;
    }
    if (ok) break;
  }
  const angle = Math.atan2(WORLD_H / 2 - y, WORLD_W / 2 - x) + (Math.random() - 0.5) * 0.6;
  p.angle = angle; p.target = angle;
  p.trail = Array.from({ length: START_LENGTH }, (_, i) => ({
    x: x - Math.cos(angle) * i * TRAIL_SPACING, y: y - Math.sin(angle) * i * TRAIL_SPACING
  }));
  p.head = { x, y };
}
function addTrailPoint(p, point) {
  // trail[0] is the live head; a new fixed body point is added every TRAIL_SPACING of travel.
  if (p.trail.length < 2 || distance(p.trail[1], point) >= TRAIL_SPACING) p.trail.unshift({ x: point.x, y: point.y });
  else p.trail[0] = { x: point.x, y: point.y };
  const desired = Math.min(MAX_TRAIL_POINTS, START_LENGTH + p.score * 3);
  while (p.trail.length > desired) p.trail.pop();
}
function collectFood(room, p, oldHead, newHead) {
  for (let i = room.food.length - 1; i >= 0; i--) {
    const f = room.food[i];
    if (pointSegmentDistance(f, oldHead, newHead) <= FOOD_RADIUS) {   // swept: no tunnelling at speed
      room.food[i] = { x: r3(randX()), y: r3(randY()) };
      room.foodDirty = true;
      p.score += 1;
    }
  }
}
function hitsBody(head, other) {
  const t = other.trail;
  for (let j = 0; j < t.length - 1; j++) if (pointSegmentDistance(head, t[j], t[j + 1]) < COLLISION_RADIUS) return true;
  return false;
}
function simulationStep(room) {
  if (!room.started) return;
  room.tickCount++;
  const dt = TICK_MS / 1000;

  for (const p of room.players.values()) {
    if (!p.alive) continue;
    // Limited turn rate = less twitchy steering.
    let d = p.target - p.angle;
    d = Math.atan2(Math.sin(d), Math.cos(d));
    const maxTurn = TURN_RATE * dt;
    p.angle += Math.max(-maxTurn, Math.min(maxTurn, d));
    const old = p.head;
    const next = {
      x: Math.max(WALL, Math.min(WORLD_W - WALL, old.x + Math.cos(p.angle) * SPEED * dt)),
      y: Math.max(WALL, Math.min(WORLD_H - WALL, old.y + Math.sin(p.angle) * SPEED * dt))
    };
    collectFood(room, p, old, next);
    addTrailPoint(p, next);
    p.head = next;
  }

  // Rules: touching ANOTHER worm's body eliminates you. A worm may cross itself freely.
  // Everyone is checked before anyone is removed, so a head-on hit eliminates both.
  const dead = [];
  for (const p of room.players.values()) {
    if (!p.alive) continue;
    for (const other of room.players.values()) {
      if (other === p || !other.alive) continue;
      if (hitsBody(p.head, other)) { dead.push(p); break; }
    }
  }
  for (const p of dead) { p.alive = false; p.elimTick = room.tickCount; }

  if (checkLastAlive(room)) return;
  broadcast(room);
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
        players: new Map(), food: [], foodDirty: true, interval: null, tickCount: 0
      };
      newFood(room);
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
      if (room.started) return;
      if (room.players.size < MIN_PLAYERS) return send(ws, { type: 'error', message: 'At least 2 players are required' });
      for (const q of room.players.values()) { q.trail = []; q.score = 0; q.alive = true; q.elimTick = Infinity; }
      for (const q of room.players.values()) spawn(room, q);
      newFood(room);
      room.started = true;
      room.endsAt = Date.now() + room.minutes * 60 * 1000;
      room.tickCount = 0;
      if (room.interval) clearInterval(room.interval);
      room.interval = setInterval(() => {
        if (Date.now() >= room.endsAt) finish(room, 'time');
        else simulationStep(room);
      }, TICK_MS);
      broadcast(room, true);
    } else if (m.type === 'steer' && room.started) {
      const p = room.players.get(ws.playerId);
      if (!p || !p.alive) return;
      const dx = Number(m.dx) || 0, dy = Number(m.dy) || 0;
      if (Math.hypot(dx, dy) > 0.001) p.target = Math.atan2(dy, dx); // worm turns toward this at TURN_RATE
    }
  });
  ws.on('close', () => removePlayer(ws));
  ws.on('error', () => removePlayer(ws));
});
function addPlayer(ws, room, m) {
  const id = String(m.playerId || crypto.randomUUID());
  ws.playerId = id;
  ws.roomCode = room.code;
  const p = {
    id, name: String(m.name || 'Player').slice(0, 20), ws,
    score: 0, alive: true, elimTick: Infinity, color: pickColor(room),
    trail: [], head: { x: 0, y: 0 }, angle: 0, target: 0
  };
  room.players.set(id, p);
  spawn(room, p);
  send(ws, { type: 'joined', roomCode: room.code });
  broadcast(room, true);
}
server.listen(port, '0.0.0.0', () => console.log(`Worm Arena server listening on ${port}`));
