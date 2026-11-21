// QR Code encoder for the hub's iPhone / iPad invitation: ISO/IEC 18004 byte mode at error
// correction level M, versions 1 to 40, with the mask chosen by the standard's penalty score.
// No dependencies. The dashboard loads it as a classic script (global QR); tests require() it.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(); else root.QR = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
'use strict';
// Level M, versions 1..40: error-correction codewords per block, and how many blocks.
const ECC_LEN = [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
const BLOCKS = [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];

// GF(256) with the QR polynomial x^8 + x^4 + x^3 + x^2 + 1.
const EXP = new Uint8Array(510), LOG = new Uint8Array(256);
for (let i = 0, x = 1; i < 255; i++) { EXP[i] = EXP[i + 255] = x; LOG[x] = i; x = (x << 1) ^ (x & 128 ? 0x11D : 0); }
const mul = (a, b) => (a && b ? EXP[LOG[a] + LOG[b]] : 0);
// Reed-Solomon generator (x - a^0)...(x - a^(n-1)), highest power first, without its leading 1.
function generator(n) {
  const g = new Uint8Array(n); g[n - 1] = 1;
  for (let i = 0, rootPower = 1; i < n; i++, rootPower = mul(rootPower, 2))
    for (let j = 0; j < n; j++) g[j] = mul(g[j], rootPower) ^ (j + 1 < n ? g[j + 1] : 0);
  return g;
}
function remainder(data, g) {
  const r = new Uint8Array(g.length);
  for (const byte of data) {
    const factor = byte ^ r[0];
    r.copyWithin(0, 1); r[r.length - 1] = 0;
    for (let i = 0; i < g.length; i++) r[i] ^= mul(g[i], factor);
  }
  return r;
}

// Modules left for codewords once every function pattern is in place.
function rawModules(v) {
  let n = (16 * v + 128) * v + 64;
  if (v >= 2) { const a = Math.floor(v / 7) + 2; n -= (25 * a - 10) * a - 55; if (v >= 7) n -= 36; }
  return n;
}
const dataCodewords = v => (rawModules(v) >> 3) - ECC_LEN[v - 1] * BLOCKS[v - 1];
// Bytes that fit: the header is a 4-bit mode and an 8-bit (16-bit from version 10) length.
const capacity = v => dataCodewords(v) - (v < 10 ? 2 : 3);
function alignment(v) {
  if (v === 1) return [];
  const count = Math.floor(v / 7) + 2, step = v === 32 ? 26 : Math.ceil((v * 4 + 4) / (count * 2 - 2)) * 2, at = [6];
  for (let pos = v * 4 + 10; at.length < count; pos -= step) at.splice(1, 0, pos);
  return at;
}

// Data codewords (mode, length, bytes, terminator, padding) split into blocks, each followed by
// its error-correction codewords, interleaved in transmission order.
function codewords(bytes, v) {
  const total = dataCodewords(v), data = new Uint8Array(total);
  let at = 0;
  const put = (value, len) => { for (let i = len - 1; i >= 0; i--, at++) data[at >> 3] |= ((value >>> i) & 1) << (7 - (at & 7)); };
  put(4, 4); put(bytes.length, v < 10 ? 8 : 16);
  for (const b of bytes) put(b, 8);
  at = (Math.min(at + 4, total * 8) + 7) & ~7;
  for (let pad = 0xEC; at < total * 8; at += 8, pad ^= 0xFD) data[at >> 3] = pad;   // 0xEC, 0x11, 0xEC...

  const blocks = BLOCKS[v - 1], ecc = ECC_LEN[v - 1], raw = rawModules(v) >> 3;
  const short = blocks - raw % blocks, len = Math.floor(raw / blocks) - ecc, g = generator(ecc), parts = [];
  for (let i = 0, k = 0; i < blocks; i++) {
    const d = data.subarray(k, k += len + (i < short ? 0 : 1));
    parts.push([d, remainder(d, g)]);
  }
  const out = new Uint8Array(raw);
  let n = 0;
  for (let i = 0; i <= len; i++) for (const [d] of parts) if (i < d.length) out[n++] = d[i];
  for (let i = 0; i < ecc; i++) for (const [, e] of parts) out[n++] = e[i];
  return out;
}

// 15 format bits (level M is 00, then the mask) with their BCH remainder, in both copies.
function writeFormat(set, size, mask) {
  let rem = mask;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  const bits = (mask << 10 | rem) ^ 0x5412, bit = i => (bits >>> i) & 1;
  for (let i = 0; i <= 5; i++) set(8, i, bit(i));
  set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8));
  for (let i = 9; i < 15; i++) set(14 - i, 8, bit(i));
  for (let i = 0; i < 8; i++) set(size - 1 - i, 8, bit(i));
  for (let i = 8; i < 15; i++) set(8, size - 15 + i, bit(i));
  set(8, size - 8, 1);   // the always-dark module
}

const MASKS = [
  (x, y) => (x + y) % 2 === 0, (x, y) => y % 2 === 0, (x, y) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => x * y % 2 + x * y % 3 === 0,
  (x, y) => (x * y % 2 + x * y % 3) % 2 === 0, (x, y) => ((x + y) % 2 + x * y % 3) % 2 === 0,
];

// The standard's four penalty rules: long runs, 2x2 blocks, finder look-alikes, dark balance.
function penalty(m, size) {
  let score = 0, dark = 0;
  for (let pass = 0; pass < 2; pass++) for (let a = 0; a < size; a++) {
    let run = 0, color = -1, recent = 0;
    for (let b = 0; b < size; b++) {
      const c = pass ? m[b * size + a] : m[a * size + b];
      if (c === color) { if (++run === 5) score += 3; else if (run > 5) score++; } else { color = c; run = 1; }
      recent = (recent << 1 | c) & 0x7FF;
      if (b >= 10 && (recent === 0x5D0 || recent === 0x05D)) score += 40;
    }
  }
  for (let y = 0; y < size - 1; y++) for (let x = 0; x < size - 1; x++) {
    const i = y * size + x, c = m[i];
    if (c === m[i + 1] && c === m[i + size] && c === m[i + size + 1]) score += 3;
  }
  for (let i = 0; i < m.length; i++) dark += m[i];
  return score + Math.floor(Math.abs(dark * 20 - m.length * 10) / m.length) * 10;
}

// Returns { version, size, mask, modules }: modules[y * size + x] is 1 for a dark module.
// Strings are encoded as UTF-8 without an ECI header, which is what phone cameras expect.
function encode(input) {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : Uint8Array.from(input);
  let version = 1;
  while (version <= 40 && capacity(version) < bytes.length) version++;
  if (version > 40) throw new RangeError('Too much data for a QR code');
  const size = version * 4 + 17, base = new Uint8Array(size * size), fixed = new Uint8Array(size * size);
  const setter = m => (x, y, on) => { if (x >= 0 && x < size && y >= 0 && y < size) { m[y * size + x] = on ? 1 : 0; fixed[y * size + x] = 1; } };
  const set = setter(base), ring = (dx, dy) => Math.max(Math.abs(dx), Math.abs(dy));
  for (let i = 0; i < size; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
  // Finder patterns with their light separators.
  for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]])
    for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) set(cx + dx, cy + dy, ring(dx, dy) !== 2 && ring(dx, dy) !== 4);
  const at = alignment(version), last = at.length - 1;
  at.forEach((cx, i) => at.forEach((cy, j) => {
    if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) return;   // the finder corners
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(cx + dx, cy + dy, ring(dx, dy) !== 1);
  }));
  writeFormat(set, size, 0);   // reserves the format area; each candidate mask rewrites it
  if (version >= 7) {
    let rem = version;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1F25);
    const bits = version << 12 | rem;
    for (let i = 0; i < 18; i++) {
      const a = size - 11 + i % 3, b = Math.floor(i / 3), on = (bits >>> i) & 1;
      set(a, b, on); set(b, a, on);
    }
  }
  // Codewords snake upwards and downwards in two-module columns from the bottom right corner,
  // stepping over the vertical timing column.
  const stream = codewords(bytes, version);
  for (let right = size - 1, n = 0; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < size; vert++) for (let j = 0; j < 2; j++) {
      const x = right - j, y = ((right + 1) & 2) === 0 ? size - 1 - vert : vert, i = y * size + x;
      if (!fixed[i] && n < stream.length * 8) { base[i] = (stream[n >> 3] >>> (7 - (n & 7))) & 1; n++; }
    }
  }
  let best = null;
  for (let mask = 0; mask < 8; mask++) {
    const modules = base.slice();
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fixed[y * size + x] && MASKS[mask](x, y)) modules[y * size + x] ^= 1;
    writeFormat(setter(modules), size, mask);
    const score = penalty(modules, size);
    if (!best || score < best.score) best = { version, size, mask, modules, score };
  }
  delete best.score;
  return best;
}

// Dark on white with a quiet zone whatever the page theme, and a whole number of device pixels
// per module so every edge stays sharp. `size` is the largest CSS width to use.
function paint(canvas, code, { size = 220, ratio = 1, quiet = 4 } = {}) {
  const n = code.size + 2 * quiet, k = Math.max(1, Math.floor(size * ratio / n)), ctx = canvas.getContext('2d');
  canvas.width = canvas.height = n * k;
  canvas.style.width = canvas.style.height = n * k / ratio + 'px';
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, n * k, n * k);
  ctx.fillStyle = '#000';
  for (let y = 0; y < code.size; y++) for (let x = 0; x < code.size; x++)
    if (code.modules[y * code.size + x]) ctx.fillRect((x + quiet) * k, (y + quiet) * k, k, k);
}

return { encode, paint, capacity };
});
