'use strict';
// Version/build gate test: sets the gate env BEFORE requiring the relay (config is
// read at load), then checks that outdated/blocked clients are rejected on `hello`
// while up-to-date clients pass. Run: node server/test_gate.js
process.env.PORT = process.env.PORT || '8798';
process.env.MIN_MOD_VERSION = '0.2.0';
process.env.BLOCKED_VERSIONS = '0.3.0';
process.env.ALLOWED_BUILD_HASHES = 'goodhash';

const assert = require('assert');
const { server, PORT } = require('./relay');
const { TestClient } = require('./test_client');

const HOST = '127.0.0.1';
let passed = 0;
function ok(name) { console.log(`  PASS  ${name}`); passed++; }

// Send hello and return whichever comes first: hello_ok or error.
async function helloResult(fields) {
  const c = new TestClient(HOST, PORT);
  await c.ready;
  c.send(Object.assign({ t: 'hello', proto: 1, name: 'T' }, fields));
  const r = await c.wait((m) => m.t === 'hello_ok' || m.t === 'error');
  c.close();
  return r;
}

(async () => {
  try {
    // Below the floor -> outdated.
    let r = await helloResult({ mver: '0.1.9' });
    assert.strictEqual(r.t, 'error');
    assert.strictEqual(r.code, 'outdated');
    ok('mver below MIN_MOD_VERSION is rejected (outdated)');

    // No mver reported at all -> treated as below floor.
    r = await helloResult({});
    assert.strictEqual(r.code, 'outdated');
    ok('missing mver with a floor set is rejected');

    // Exactly at the floor -> allowed (build allowlist satisfied).
    r = await helloResult({ mver: '0.2.0', bhash: 'goodhash' });
    assert.strictEqual(r.t, 'hello_ok');
    ok('mver at the floor with allowed build passes');

    // Newer than floor -> allowed.
    r = await helloResult({ mver: '1.0.0', bhash: 'goodhash' });
    assert.strictEqual(r.t, 'hello_ok');
    ok('mver above the floor passes');

    // Explicitly blocked version -> outdated even though >= floor.
    r = await helloResult({ mver: '0.3.0', bhash: 'goodhash' });
    assert.strictEqual(r.code, 'outdated');
    ok('BLOCKED_VERSIONS kill-switch rejects a specific version');

    // Build hash not in the allowlist -> build_blocked.
    r = await helloResult({ mver: '0.2.0', bhash: 'tampered' });
    assert.strictEqual(r.code, 'build_blocked');
    ok('build hash outside ALLOWED_BUILD_HASHES is rejected');

    // Null build hash is fail-open (allowed when version is fine).
    r = await helloResult({ mver: '0.2.0' });
    assert.strictEqual(r.t, 'hello_ok');
    ok('null build hash is fail-open (not blocked)');

    console.log(`\nAll ${passed} checks passed.`);
    server.close();
    process.exit(0);
  } catch (e) {
    console.error('\nTEST FAILED:', e);
    server.close();
    process.exit(1);
  }
})();
