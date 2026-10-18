const http = require('http');
const { WebSocketServer } = require('ws');
const crypto = require('crypto');

const port = Number(process.env.PORT || 8080);
const server = http.createServer((req, res) => {
  res.writeHead(200, {'content-type':'text/plain'});
  res.end('Worm Arena WebSocket server is running.\n');
});
const wss = new WebSocketServer({ server });
const rooms = new Map();
const validMinutes = [5, 7, 10];

function code() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let out = '';
  for (let i=0;i<6;i++) out += chars[crypto.randomInt(chars.length)];
  return out;
}
function send(ws, obj) { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); }
function publicState(room) {
  return {
    type:'state', roomCode:room.code, minutes:room.minutes,
    started:room.started, secondsLeft:room.started ? Math.max(0, Math.ceil((room.endsAt-Date.now())/1000)) : 0,
    players:[...room.players.values()].map(p => ({id:p.id,name:p.name,host:p.id===room.hostId})),
    positions:Object.fromEntries([...room.players.values()].map(p => [p.id,{x:p.x,y:p.y}]))
  };
}
function broadcast(room) {
  const data = publicState(room);
  for (const p of room.players.values()) send(p.ws, data);
}
function finish(room) {
  room.started = false;
  for (const p of room.players.values()) send(p.ws, {type:'ended', roomCode:room.code});
  broadcast(room);
}
function removePlayer(ws) {
  const roomCode = ws.roomCode;
  if (!roomCode) return;
  const room = rooms.get(roomCode);
  if (!room) return;
  room.players.delete(ws.playerId);
  if (!room.players.size) {
    if (room.interval) clearInterval(room.interval);
    rooms.delete(roomCode);
  } else {
    if (room.hostId === ws.playerId) room.hostId = room.players.keys().next().value;
    broadcast(room);
  }
}
wss.on('connection', ws => {
  ws.on('message', raw => {
    let m;
    try { m = JSON.parse(raw.toString()); } catch { return send(ws,{type:'error',message:'Invalid message'}); }
    if (m.type === 'create') {
      if (ws.roomCode) removePlayer(ws);
      let roomCode = code();
      while (rooms.has(roomCode)) roomCode = code();
      const minutes = validMinutes.includes(Number(m.minutes)) ? Number(m.minutes) : 5;
      const room = {code:roomCode,minutes,started:false,endsAt:0,hostId:String(m.playerId),players:new Map(),interval:null};
      rooms.set(roomCode,room);
      addPlayer(ws,room,m);
      return;
    }
    if (m.type === 'join') {
      const room = rooms.get(String(m.roomCode || '').toUpperCase());
      if (!room) return send(ws,{type:'error',message:'Room not found'});
      if (room.started) return send(ws,{type:'error',message:'Match already started'});
      if (room.players.size >= 8) return send(ws,{type:'error',message:'Room is full (8 players maximum)'});
      addPlayer(ws,room,m);
      return;
    }
    const room = rooms.get(ws.roomCode);
    if (!room || !room.players.has(ws.playerId)) return;
    if (m.type === 'start') {
      if (String(m.playerId) !== room.hostId) return send(ws,{type:'error',message:'Only the host can start'});
      if (room.players.size < 2) return send(ws,{type:'error',message:'At least 2 players are required'});
      room.started = true;
      room.endsAt = Date.now() + room.minutes * 60 * 1000;
      if (room.interval) clearInterval(room.interval);
      room.interval = setInterval(() => {
        if (Date.now() >= room.endsAt) {
          clearInterval(room.interval); room.interval = null; finish(room);
        } else broadcast(room);
      }, 1000);
      broadcast(room);
    } else if (m.type === 'move' && room.started) {
      const p = room.players.get(ws.playerId);
      p.x = Math.max(0.03, Math.min(0.97, Number(m.x) || 0.5));
      p.y = Math.max(0.03, Math.min(0.97, Number(m.y) || 0.5));
      broadcast(room);
    }
  });
  ws.on('close', () => removePlayer(ws));
  ws.on('error', () => removePlayer(ws));
});
function addPlayer(ws,room,m) {
  const id = String(m.playerId || crypto.randomUUID());
  ws.playerId = id; ws.roomCode = room.code;
  room.players.set(id,{id,name:String(m.name || 'Player').slice(0,20),ws,x:Math.random()*.8+.1,y:Math.random()*.8+.1});
  send(ws,{type:'joined',roomCode:room.code});
  broadcast(room);
}
server.listen(port,'0.0.0.0',()=>console.log(`Worm Arena server listening on ${port}`));
