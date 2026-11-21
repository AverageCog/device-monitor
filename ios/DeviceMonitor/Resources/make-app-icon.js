// Renders the iOS app icon to Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png with no dependencies.
//   node ios/DeviceMonitor/Resources/make-app-icon.js
//
// Same gauge as the desktop icon (build/make-icon.js), redrawn for iOS: the artwork is full-bleed
// (the system applies the corner mask) and the PNG has no alpha channel, which App Store Connect
// requires. This script is excluded from the app target in the project file.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const CRC = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
const crc32 = buf => { let c = -1; for (const b of buf) c = CRC[(c ^ b) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
// Opaque 8-bit RGB (colour type 2): there is no alpha channel to strip later.
function png(size, pixel) {
  const stride = size * 3 + 1;
  const raw = Buffer.alloc(size * stride);
  const SS = 4; // supersampling for anti-aliasing
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0;
      for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
        const p = pixel((x + (sx + 0.5) / SS) / size, (y + (sy + 0.5) / SS) / size);
        r += p[0]; g += p[1]; b += p[2];
      }
      const o = y * stride + 1 + x * 3, n = SS * SS;
      raw[o] = Math.round(r / n); raw[o + 1] = Math.round(g / n); raw[o + 2] = Math.round(b / n);
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 2;
  // sRGB chunk so the colours are not left to interpretation.
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('sRGB', Buffer.from([0])), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const TOP = hex('#1a1a19'), BOTTOM = hex('#0d0d0d'), TRACK = hex('#383835'), CPU = hex('#3987e5'), GPU = hex('#d95926'), ACCENT = hex('#9085e9'), NEEDLE = hex('#f0efec');

// Gauge: 270° track with a 3-colour sweep (CPU / accent / GPU) and a needle, as in build/make-icon.js.
// The open side of the arc faces down, so the centre sits a little low to look optically centred.
const CY = 0.538, R = 0.305, W = 0.074, HUB = 0.05, NEEDLE_W = 0.02;
function icon(u, v) {
  const x = u - 0.5, y = v - CY;
  const d = Math.hypot(x, y);
  const ang = Math.atan2(y, x) * 180 / Math.PI;   // 0 = right, 90 = down
  const t = (ang - 135 + 360) % 360;               // 0..270 along the arc, starting bottom-left
  if (Math.abs(d - R) < W / 2 && t <= 270) {
    if (t < 95) return CPU;
    if (t < 185) return ACCENT;
    if (t < 205) return GPU;
    return TRACK;
  }
  if (d < HUB) return NEEDLE;
  const na = (135 + 205) * Math.PI / 180, nx = Math.cos(na), ny = Math.sin(na);
  const along = x * nx + y * ny, across = Math.abs(-x * ny + y * nx);
  if (along > 0 && along < R - W && across < NEEDLE_W) return NEEDLE;
  return TOP.map((c, i) => c + (BOTTOM[i] - c) * v);   // surface-1 fading to the page colour
}

const out = path.join(__dirname, 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon-1024.png');
fs.writeFileSync(out, png(1024, icon));
console.log('icon written to', out);
