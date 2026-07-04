'use strict';
// Loopback test: starts the relay in-process and exercises code-room matchmaking + relay.
// Run: node server/test_loopback.js
const assert = require('assert');
const { server, PORT } = require('./relay');
const { TestClient } = require('./test_client');

const HOST = '127.0.0.1';
let passed = 0;
function ok(name) { console.log(`  PASS  ${name}`); passed++; }

async function hello(c, name) {
  await c.ready;
  c.send({ t: 'hello', proto: 1, name });
  const r = await c.waitType('hello_ok');
  assert.strictEqual(r.proto, 1);
}

async function testCodeRoom() {
  const a = new TestClient(HOST, PORT);
  const b = new TestClient(HOST, PORT);
  await hello(a, 'Red'); await hello(b, 'Blue');

  a.send({ t: 'create_room', format: 'single3', ruleset: { level_cap: 50 } });
  const created = await a.waitType('room_created');
  assert.ok(created.code && created.code.length === 5);
  ok('create_room returns 5-char code');

  b.send({ t: 'join_room', code: created.code });
  const ma = await a.waitType('matched');
  const mb = await b.waitType('matched');
  assert.strictEqual(ma.match_id, mb.match_id);
  assert.strictEqual(ma.is_creator, true);
  assert.strictEqual(mb.is_creator, false);
  assert.strictEqual(ma.opponent.name, 'Blue');
  assert.strictEqual(mb.opponent.name, 'Red');
  ok('join_room pairs both peers with same match_id');

  // relay battle messages both ways (e.g. bhello nonce exchange)
  a.send({ t: 'relay', data: { t: 'bhello', nonce: 'AAAA', mod_ver: '0.1' } });
  const pb = await b.waitType('peer_msg');
  assert.strictEqual(pb.data.t, 'bhello');
  assert.strictEqual(pb.data.nonce, 'AAAA');
  ok('relay A->B delivers verbatim');

  b.send({ t: 'relay', data: { t: 'bhello', nonce: 'BBBB', mod_ver: '0.1' } });
  const pa = await a.waitType('peer_msg');
  assert.strictEqual(pa.data.nonce, 'BBBB');
  ok('relay B->A delivers verbatim');

  // peer_left on disconnect
  const left = b.waitType('peer_left');
  a.close();
  const lv = await left;
  assert.strictEqual(lv.reason, 'close');
  ok('peer_left fired when opponent disconnects');
  b.close();
}

async function testQuickMatch() {
  const a = new TestClient(HOST, PORT);
  const b = new TestClient(HOST, PORT);
  await hello(a, 'Ash'); await hello(b, 'Gary');

  const rsA = { level_cap: 50, iv_flat: 31 };
  a.send({ t: 'quick_match', format: 'single3', mod_version: '0.1.0', ruleset: rsA });
  const qa = await a.waitType('queued');
  assert.strictEqual(qa.format, 'single3');
  ok('first quick_match player is queued');

  // Second player with the same format + mod_version pairs immediately.
  b.send({ t: 'quick_match', format: 'single3', mod_version: '0.1.0',
           ruleset: { level_cap: 99 } });
  const ma = await a.waitType('matched');
  const mb = await b.waitType('matched');
  assert.strictEqual(ma.match_id, mb.match_id);
  assert.strictEqual(ma.format, 'single3');
  ok('same format + version quick_match pairs both peers');

  // Server relays the WAITING player's ruleset to both, so hashes agree.
  assert.deepStrictEqual(ma.ruleset, rsA);
  assert.deepStrictEqual(mb.ruleset, rsA);
  ok('quick_match relays the waiting player ruleset to both peers');

  a.close(); b.close();
}

async function testQuickMatchGating() {
  const a = new TestClient(HOST, PORT);
  const b = new TestClient(HOST, PORT);
  const c = new TestClient(HOST, PORT);
  await hello(a, 'A'); await hello(b, 'B'); await hello(c, 'C');

  // A waits on single3 / v0.1.0.
  a.send({ t: 'quick_match', format: 'single3', mod_version: '0.1.0', ruleset: {} });
  await a.waitType('queued');

  // B has a DIFFERENT mod_version -> different queue, must not steal A's match.
  b.send({ t: 'quick_match', format: 'single3', mod_version: '9.9.9', ruleset: {} });
  await b.waitType('queued');
  let bMatched = false;
  b.waitType('matched', 400).then(() => { bMatched = true; }).catch(() => {});

  // C matches A's version -> pairs with A (not B).
  c.send({ t: 'quick_match', format: 'single3', mod_version: '0.1.0', ruleset: {} });
  const ma = await a.waitType('matched');
  const mc = await c.waitType('matched');
  assert.strictEqual(ma.match_id, mc.match_id);
  assert.strictEqual(ma.opponent.name, 'C');
  await new Promise((r) => setTimeout(r, 450));
  assert.strictEqual(bMatched, false);
  ok('mod_version gates the queue (mismatched version never pairs)');

  a.close(); b.close(); c.close();
}

async function testBadCode() {
  const a = new TestClient(HOST, PORT);
  await hello(a, 'Lost');
  a.send({ t: 'join_room', code: 'ZZZZZ' });
  const e = await a.waitType('error');
  assert.strictEqual(e.code, 'no_room');
  ok('joining a nonexistent room returns no_room error');
  a.close();
}

(async () => {
  try {
    await testCodeRoom();
    await testBadCode();
    await testQuickMatch();
    await testQuickMatchGating();
    console.log(`\nAll ${passed} checks passed.`);
    server.close();
    process.exit(0);
  } catch (e) {
    console.error('\nTEST FAILED:', e);
    server.close();
    process.exit(1);
  }
})();
