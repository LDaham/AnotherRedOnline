'use strict';
// Another Red Online — relay + code-room matchmaking server.
// Pure Node `net`, no external deps. Runs on a tiny (free-tier) VPS. See PROTOCOL.md §3.
//
// Server is an *opaque relay*: it pairs two peers — by shared room code, or via the
// random quick-match queue (same format + mod_version) — and forwards their battle
// messages verbatim. Canonical side (host/guest) is decided peer-to-peer via nonce
// comparison (PROTOCOL.md §4); the server only tracks who is paired with whom. No
// result reporting, no stats DB.

const net = require('net');
const crypto = require('crypto');
const { encode, FrameDecoder } = require('./protocol');

const PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 8787;
const PROTO = 1;

// --- version / build gate (global force-update + kill-switch lever) ------------
// All env-tuned and DEFAULT-OFF, so a fresh deploy blocks nobody. This is the
// server "floor": P2P mver ([003] bhello) only compares the two peers, so two
// equally-outdated clients slip past it — the server is the only place that can
// enforce a global minimum. Clients self-report `mver`/`bhash` in `hello`, so
// this stops casual/outdated clients, not a determined reverser (documented).
//   MIN_MOD_VERSION      e.g. "0.2.0"  — reject anything older (null = no floor)
//   BLOCKED_VERSIONS     e.g. "0.1.3,0.1.4" — targeted kill-switch for bad builds
//   ALLOWED_BUILD_HASHES e.g. "ab12..,cd34.." — allowlist of known-good [020] hashes
//                        (empty = allow all; a client reporting null is not blocked)
const MIN_MOD_VERSION = process.env.MIN_MOD_VERSION || null;
const csv = (s) => (s || '').split(',').map((x) => x.trim()).filter(Boolean);
const BLOCKED_VERSIONS = new Set(csv(process.env.BLOCKED_VERSIONS));
const ALLOWED_BUILD_HASHES = new Set(csv(process.env.ALLOWED_BUILD_HASHES));

// Numeric dotted-version compare: -1 / 0 / 1. Missing/short parts count as 0.
function cmpVersion(a, b) {
  const pa = String(a || '').split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b || '').split('.').map((n) => parseInt(n, 10) || 0);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

// Reason this client may not matchmake, or null if allowed. build_hash checks are
// fail-open on a null hash (mirrors the client's [020] fail-open philosophy).
function gateReason(client) {
  const v = client.modVersion;
  if (MIN_MOD_VERSION && (v == null || cmpVersion(v, MIN_MOD_VERSION) < 0)) {
    return { code: 'outdated', msg: `update required (min ${MIN_MOD_VERSION})` };
  }
  if (v != null && BLOCKED_VERSIONS.has(v)) {
    return { code: 'outdated', msg: `version ${v} is blocked` };
  }
  if (ALLOWED_BUILD_HASHES.size && client.buildHash != null &&
      !ALLOWED_BUILD_HASHES.has(client.buildHash)) {
    return { code: 'build_blocked', msg: 'build not allowed' };
  }
  return null;
}

let nextClientId = 1;
const rooms = new Map();          // code -> client (waiting host)
const queues = new Map();         // "format|modver" -> [clients] (FIFO quick-match)
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

// Quick-match queue key: only pair players on the same format AND mod_version, so an
// out-of-date client can never be matched into a battle it would abort in bhello.
function qkey(format, modver) { return `${format}|${modver || ''}`; }

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
  // Also pull the client out of any quick-match queue it is waiting in.
  for (const [key, q] of queues) {
    const i = q.indexOf(client);
    if (i !== -1) q.splice(i, 1);
    if (q.length === 0) queues.delete(key);
  }
}

function handle(client, msg) {
  // A gated client's socket is being closed; ignore anything it races in before
  // the FIN (defense-in-depth beyond the hello gate).
  if (client.blocked && msg.t !== 'ping') {
    send(client, { t: 'error', code: client.blocked.code, msg: client.blocked.msg });
    return;
  }
  switch (msg.t) {
    case 'hello': {
      client.proto = msg.proto;
      client.name = (msg.name || 'Trainer').toString().slice(0, 24);
      client.modVersion = (msg.mver != null) ? String(msg.mver) : null;
      client.buildHash = (msg.bhash != null) ? String(msg.bhash) : null;
      if (msg.proto !== PROTO) {
        send(client, { t: 'error', code: 'proto', msg: `server proto ${PROTO}` });
        client.socket.end();
        return;
      }
      const gate = gateReason(client);
      if (gate) {
        client.blocked = gate;
        send(client, { t: 'error', code: gate.code, msg: gate.msg });
        log(`reject ${client.id} ${gate.code} v=${client.modVersion} bh=${client.buildHash}`);
        client.socket.end();
        return;
      }
      send(client, { t: 'hello_ok', proto: PROTO });
      break;
    }

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

    case 'quick_match': {
      leaveMatchmaking(client);            // never double-queue / drop any stale room
      client.format = msg.format;
      client.ruleset = msg.ruleset;
      const key = qkey(msg.format, msg.mod_version);
      const q = queues.get(key) || [];
      let opp = null;
      while (q.length) {                    // take the next live waiter (skip dead sockets)
        const c = q.shift();
        if (c !== client && c.socket.writable) { opp = c; break; }
      }
      if (opp) {
        if (q.length) queues.set(key, q); else queues.delete(key);
        // Same mod_version (queue key) => identical default ruleset; reuse the waiting
        // player's so both peers receive a byte-identical ruleset in `matched` and
        // their ruleset_hash always agrees.
        pair(opp, client, msg.format, opp.ruleset || msg.ruleset);
      } else {
        q.push(client);
        queues.set(key, q);
        send(client, { t: 'queued', format: msg.format });
        log(`quick_match queued ${client.id} key=${key}`);
      }
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
    modVersion: null, buildHash: null, blocked: null,
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
