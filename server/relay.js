'use strict';
// Another Red Online — relay + code-room matchmaking server.
// Pure Node `net`, no external deps. Runs on a tiny (free-tier) VPS. See PROTOCOL.md §3.
//
// Server is an *opaque relay*: it pairs two peers (by shared room code only) and
// forwards their battle messages verbatim. Canonical side (host/guest) is decided
// peer-to-peer via nonce comparison (PROTOCOL.md §4); the server only tracks who is
// paired with whom. No random matchmaking, no result reporting, no stats DB.

const net = require('net');
const crypto = require('crypto');
const { encode, FrameDecoder } = require('./protocol');

const PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 8787;
const PROTO = 1;

let nextClientId = 1;
const rooms = new Map();          // code -> client (waiting host)
const matches = new Map();        // matchId -> { a, b }

function log(...a) { console.log(new Date().toISOString(), ...a); }

function send(client, obj) {
  if (client.socket.writable) client.socket.write(encode(obj));
}

function genCode() {
  // 5-char unambiguous code (no 0/O/1/I)
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code;
  do {
    code = '';
    for (let i = 0; i < 5; i++) code += alphabet[crypto.randomInt(alphabet.length)];
  } while (rooms.has(code));
  return code;
}

function pair(a, b, format, ruleset) {
  const matchId = crypto.randomUUID();
  const m = { id: matchId, a, b, format, ruleset };
  matches.set(matchId, m);
  a.match = m; b.match = m;
  a.peer = b; b.peer = a;
  // `is_creator` is bookkeeping only; final side is decided by nonce in bhello.
  send(a, { t: 'matched', match_id: matchId, is_creator: true,
            opponent: { name: b.name }, format, ruleset });
  send(b, { t: 'matched', match_id: matchId, is_creator: false,
            opponent: { name: a.name }, format, ruleset });
  log(`matched ${a.id}<->${b.id} match=${matchId} format=${format}`);
}

function leaveMatchmaking(client) {
  for (const [code, c] of rooms) if (c === client) rooms.delete(code);
}

function handle(client, msg) {
  switch (msg.t) {
    case 'hello':
      client.proto = msg.proto;
      client.name = (msg.name || 'Trainer').toString().slice(0, 24);
      if (msg.proto !== PROTO) {
        send(client, { t: 'error', code: 'proto', msg: `server proto ${PROTO}` });
        client.socket.end();
        return;
      }
      send(client, { t: 'hello_ok', proto: PROTO });
      break;

    case 'create_room': {
      leaveMatchmaking(client);
      const code = genCode();
      client.format = msg.format;
      client.ruleset = msg.ruleset;
      rooms.set(code, client);
      client.roomCode = code;
      send(client, { t: 'room_created', code });
      log(`room ${code} created by ${client.id}`);
      break;
    }

    case 'join_room': {
      const code = (msg.code || '').toString().toUpperCase();
      const host = rooms.get(code);
      if (!host) { send(client, { t: 'error', code: 'no_room', msg: 'room not found' }); return; }
      if (host === client) { send(client, { t: 'error', code: 'self', msg: 'cannot join own room' }); return; }
      rooms.delete(code);
      pair(host, client, host.format, host.ruleset);
      break;
    }

    case 'cancel':
      leaveMatchmaking(client);
      send(client, { t: 'cancelled' });
      break;

    case 'relay':
      // forward battle message verbatim to peer
      if (client.peer) send(client.peer, { t: 'peer_msg', data: msg.data });
      break;

    case 'ping':
      send(client, { t: 'pong', ts: msg.ts });
      break;

    default:
      send(client, { t: 'error', code: 'bad_type', msg: `unknown type ${msg.t}` });
  }
}

const server = net.createServer((socket) => {
  socket.setNoDelay(true);
  const client = {
    id: nextClientId++, socket, dec: new FrameDecoder(),
    name: 'Trainer', proto: null, peer: null, match: null,
  };
  log(`conn ${client.id} from ${socket.remoteAddress}`);

  socket.on('data', (chunk) => {
    let msgs;
    try { msgs = client.dec.push(chunk); }
    catch (e) { log(`frame error ${client.id}: ${e.message}`); socket.destroy(); return; }
    for (const m of msgs) {
      try { handle(client, m); }
      catch (e) { log(`handler error ${client.id}: ${e.message}`); }
    }
  });

  const cleanup = (why) => {
    leaveMatchmaking(client);
    if (client.peer && client.peer.socket.writable) {
      send(client.peer, { t: 'peer_left', reason: why });
      client.peer.peer = null;
    }
    if (client.match) matches.delete(client.match.id);
    client.peer = null;
    log(`disconnect ${client.id} (${why})`);
  };
  socket.on('close', () => cleanup('close'));
  socket.on('error', (e) => { log(`socket error ${client.id}: ${e.message}`); });
});

server.listen(PORT, () => log(`relay listening on :${PORT} (proto ${PROTO})`));

module.exports = { server, PORT };
