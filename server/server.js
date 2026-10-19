const http = require('http');
const { WebSocketServer } = require('ws');
const crypto = require('crypto');

const port = Number(process.env.PORT || 8080);
const server = http.createServer((req, res) => {
  res.writeHead(200, {'content-type':'text/plain'});
  res.end('Worm Arena multiplayer server is running.\n');
});
const wss = new WebSocketServer({ server });
const rooms = new Map();
const validMinutes = [5, 7, 10];
const MAX_PLAYERS = 8;
const FOOD_COUNT = 45;

function roomCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let out = '';
  for (let i=0;i<6;i++) out += chars[crypto.randomInt(chars.length)];
  return out;
}
function rand() { return 0.08 + Math.random() * 0.84; }
function foodItem() { return {id:crypto.randomUUID(),x:rand(),y:rand()}; }
function send(ws, obj) { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); }

function publicState(room) {
  return {
    type:'state', roomCode:room.code, minutes:room.minutes,
    started:room.started,
    secondsLeft:room.started ? Math.max(0, Math.ceil((room.endsAt-Date.now())/1000)) : 0,
    players:[...room.players.values()].map(p => ({
      id:p.id,name:p.name,host:p.id===room.hostId,score:p.score,length:p.trail.length,alive:p.alive
    })),
    worms:Object.fromEntries([...room.players.values()].map(p => [p.id,{
      trail:p.trail, alive:p.alive, score:p.score, name:p.name
    }])),
    food:room.food
  };
}
function broadcast(room) {
  const data = publicState(room);
  for (const p of room.players.values()) send(p.ws, data);
}
function finish(room) {
  room.started = false;
  if (room.interval) clearInterval(room.interval);
  room.interval = null;
  const ranking = [...room.players.values()].sort((a,b)=>b.score-a.score)
    .map((p,i)=>({rank:i+1,id:p.id,name:p.name,score:p.score,length:p.trail.length}));
  for (const p of room.players.values()) send(p.ws, {type:'ended',roomCode:room.code,ranking});
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
function respawn(p) {
  p.alive = true; p.score = Math.max(0,p.score-2);
  const x=rand(), y=rand();
  p.trail = Array.from({length:8},(_,i)=>({x:Math.max(.02,x-i*.008),y}));
}
function step(room) {
  if (!room.started) return;
  // Server-authoritative worm growth and food collection.
  for (const p of room.players.values()) {
    if (!p.alive || !p.trail.length) continue;
    const head = p.trail[0];
    for (let i=room.food.length-1;i>=0;i--) {
      const f=room.food[i];
      if (Math.hypot(head.x-f.x,head.y-f.y)<0.035) {
        room.food.splice(i,1); p.score += 1;
        p.growth = (p.growth||0)+4;
        room.food.push(foodItem());
      }
    }
    // Keep tail in place when growth was earned; otherwise trim to target length.
    if (p.growth>0) p.growth--;
    else if (p.trail.length > Math.max(8, 8 + p.score*4)) p.trail.pop();
  }
  // Head-to-body collisions eliminate a worm and respawn it after a short penalty.
  for (const p of room.players.values()) {
    if (!p.alive || p.trail.length<8) continue;
    const h=p.trail[0];
    let hit=false;
    for (const other of room.players.values()) {
      if (!other.alive) continue;
      const start=other.id===p.id?8:4;
      for (let j=start;j<other.trail.length;j++) {
        const q=other.trail[j];
        if (Math.hypot(h.x-q.x,h.y-q.y)<0.018) { hit=true; break; }
      }
      if (hit) break;
    }
    if (hit) {
      p.alive=false;
      p.score=Math.max(0,p.score-3);
      setTimeout(()=>{ if (rooms.get(room.code)===room && room.started && room.players.has(p.id)) { respawn(p); broadcast(room); } }, 1800);
    }
  }
  broadcast(room);
}
wss.on('connection', ws => {
  ws.on('message', raw => {
    let m;
    try { m=JSON.parse(raw.toString()); } catch { return send(ws,{type:'error',message:'Invalid message'}); }
    if (m.type==='create') {
      if (ws.roomCode) removePlayer(ws);
      let code=roomCode(); while(rooms.has(code)) code=roomCode();
      const minutes=validMinutes.includes(Number(m.minutes))?Number(m.minutes):5;
      const room={code,minutes,started:false,endsAt:0,hostId:String(m.playerId),players:new Map(),food:Array.from({length:FOOD_COUNT},foodItem),interval:null};
      rooms.set(code,room); addPlayer(ws,room,m); return;
    }
    if (m.type==='join') {
      const room=rooms.get(String(m.roomCode||'').toUpperCase());
      if (!room) return send(ws,{type:'error',message:'Room not found'});
      if (room.started) return send(ws,{type:'error',message:'Match already started'});
      if (room.players.size>=MAX_PLAYERS) return send(ws,{type:'error',message:'Room is full (8 players maximum)'});
      addPlayer(ws,room,m); return;
    }
    const room=rooms.get(ws.roomCode);
    if (!room || !room.players.has(ws.playerId)) return;
    if (m.type==='start') {
      if (String(m.playerId)!==room.hostId) return send(ws,{type:'error',message:'Only the host can start'});
      if (room.players.size<2) return send(ws,{type:'error',message:'At least 2 players are required'});
      room.started=true; room.endsAt=Date.now()+room.minutes*60*1000;
      if (room.interval) clearInterval(room.interval);
      room.interval=setInterval(()=>{
        if(Date.now()>=room.endsAt) finish(room);
        else step(room);
      },100);
      broadcast(room);
    } else if (m.type==='move' && room.started) {
      const p=room.players.get(ws.playerId);
      if (!p || !p.alive) return;
      const old=p.trail[0];
      const nx=Math.max(.02,Math.min(.98,Number(m.x)||old.x));
      const ny=Math.max(.02,Math.min(.98,Number(m.y)||old.y));
      const dx=nx-old.x, dy=ny-old.y;
      // Limit per-message movement to reduce teleporting.
      const distance=Math.hypot(dx,dy), maxStep=.035;
      const scale=distance>maxStep?maxStep/distance:1;
      const head={x:old.x+dx*scale,y:old.y+dy*scale};
      p.trail.unshift(head);
      if(p.trail.length>Math.max(12,8+p.score*4)+8) p.trail.length=Math.max(12,8+p.score*4)+8;
    }
  });
  ws.on('close',()=>removePlayer(ws));
  ws.on('error',()=>removePlayer(ws));
});
function addPlayer(ws,room,m) {
  const id=String(m.playerId||crypto.randomUUID());
  const x=rand(), y=rand();
  ws.playerId=id; ws.roomCode=room.code;
  room.players.set(id,{id,name:String(m.name||'Player').slice(0,20),ws,score:0,alive:true,growth:0,
    trail:Array.from({length:8},(_,i)=>({x:Math.max(.02,x-i*.008),y}))});
  send(ws,{type:'joined',roomCode:room.code}); broadcast(room);
}
server.listen(port,'0.0.0.0',()=>console.log(`Worm Arena gameplay server listening on ${port}`));
