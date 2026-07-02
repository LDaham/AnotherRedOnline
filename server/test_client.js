'use strict';
// Minimal Node client for testing the relay (same wire protocol as the Ruby client).
const net = require('net');
const { encode, FrameDecoder } = require('./protocol');

class TestClient {
  constructor(host, port) {
    this.dec = new FrameDecoder();
    this.inbox = [];
    this.waiters = [];
    this.socket = net.connect(port, host);
    this.socket.setNoDelay(true);
    this.ready = new Promise((res, rej) => {
      this.socket.once('connect', res);
      this.socket.once('error', rej);
    });
    this.socket.on('data', (chunk) => {
      for (const m of this.dec.push(chunk)) {
        const w = this.waiters.findIndex((x) => x.pred(m));
        if (w >= 0) { const { resolve } = this.waiters.splice(w, 1)[0]; resolve(m); }
        else this.inbox.push(m);
      }
    });
  }
  send(obj) { this.socket.write(encode(obj)); }
  // wait for a message matching predicate (checks already-buffered inbox first)
  wait(pred, timeoutMs = 2000) {
    const i = this.inbox.findIndex(pred);
    if (i >= 0) return Promise.resolve(this.inbox.splice(i, 1)[0]);
    return new Promise((resolve, reject) => {
      const entry = { pred, resolve };
      this.waiters.push(entry);
      setTimeout(() => {
        const k = this.waiters.indexOf(entry);
        if (k >= 0) { this.waiters.splice(k, 1); reject(new Error('wait timeout')); }
      }, timeoutMs);
    });
  }
  waitType(t, timeoutMs) { return this.wait((m) => m.t === t, timeoutMs); }
  close() { this.socket.destroy(); }
}

module.exports = { TestClient };
