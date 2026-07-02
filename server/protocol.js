'use strict';
// Wire framing: [len:uint32_be][json utf8]. See PROTOCOL.md.

const MAX_FRAME = 64 * 1024;

function encode(obj) {
  const json = Buffer.from(JSON.stringify(obj), 'utf8');
  const head = Buffer.allocUnsafe(4);
  head.writeUInt32BE(json.length, 0);
  return Buffer.concat([head, json]);
}

// Stateful frame decoder. Feed chunks; get back array of parsed messages.
class FrameDecoder {
  constructor() { this.buf = Buffer.alloc(0); }
  push(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    const out = [];
    while (this.buf.length >= 4) {
      const len = this.buf.readUInt32BE(0);
      if (len > MAX_FRAME) throw new Error(`frame too large: ${len}`);
      if (this.buf.length < 4 + len) break;
      const body = this.buf.slice(4, 4 + len);
      this.buf = this.buf.slice(4 + len);
      out.push(JSON.parse(body.toString('utf8')));
    }
    return out;
  }
}

module.exports = { encode, FrameDecoder, MAX_FRAME };
