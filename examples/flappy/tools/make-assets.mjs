// Generates app/sprites/dragon.png (two-frame 24x16 spritesheet -> 48x16)
// and app/sounds/{flap,score,hit}.wav. Deterministic, no image/audio deps:
// Rerun after editing:  node tools/make-assets.mjs
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

// ── dragon spritesheet: frame A (wing up) + frame B (wing down) ──────
const PALETTE = {
  '.': null,               // transparent
  G: [0x2a, 0x9d, 0x4a],   // body green
  D: [0x1e, 0x7a, 0x38],   // dark green (wing)
  T: [0x21, 0x7f, 0x3e],   // tail
  B: [0xcf, 0xe8, 0x8a],   // belly
  O: [0xe8, 0x70, 0x3a],   // snout
  W: [0xff, 0xff, 0xff],   // eye white
  K: [0x10, 0x10, 0x10],   // pupil
  H: [0xe8, 0xc8, 0x3a],   // horn
};

const FRAME_A = [ // wing raised
  '........................',
  '.......DDD......H.......',
  '......DDDDD....HH.......',
  '......DDDDD..GGGG.......',
  '.T....DDDDD.GGGGGG......',
  '.TT..GGDDDGGGGWKGG......',
  '..TTGGGGGGGGGGGGGGOO....',
  '...TTGGGGGGGGGGGGGOOO...',
  '....TGGGBBBBBBGGGGOO....',
  '.....GGBBBBBBBBGGG......',
  '.....GGBBBBBBBBGG.......',
  '......GGBBBBBBGG........',
  '.......GGGGGGGG.........',
  '........GG..GG..........',
  '.......GG....GG.........',
  '........................',
];

const FRAME_B = [ // wing tucked low
  '........................',
  '................H.......',
  '...............HH.......',
  '.............GGGG.......',
  '.T..........GGGGGG......',
  '.TT..GGGGGGGGGWKGG......',
  '..TTGGGGGGGGGGGGGGOO....',
  '...TTGGGGGGGGGGGGGOOO...',
  '....TGGGBBBBBBGGGGOO....',
  '.....GGBBBBBBBBGGG......',
  '.....GDDDDBBBBBGG.......',
  '......GDDDDDBBGG........',
  '......DDDDDGGGG.........',
  '.......DDDGG.GG.........',
  '.......GG.....GG........',
  '........................',
];

const FW = 24, FH = 16;
const sheet = new Uint8Array(FW * 2 * FH * 4); // XRGB-as-BGRX? encodePng expects BGRX (CartHost order)
function putFrame(rows, xoff) {
  for (let y = 0; y < FH; y++) {
    for (let x = 0; x < FW; x++) {
      const c = PALETTE[rows[y][x]];
      const i = (y * FW * 2 + xoff + x) * 4;
      if (!c) { sheet[i + 3] = 0; continue; } // stb reads alpha from PNG; encoder writes RGB only...
      sheet[i] = c[2]; sheet[i + 1] = c[1]; sheet[i + 2] = c[0]; sheet[i + 3] = 255;
    }
  }
}
putFrame(FRAME_A, 0);
putFrame(FRAME_B, FW);

import { deflateSync } from 'node:zlib';
function crcTable() {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
}
const CRC = crcTable();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const out = Buffer.alloc(8 + data.length + 4);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'ascii');
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}
function encodePngRgba(bgra, width, height) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 6; // RGBA
  const raw = Buffer.alloc(height * (1 + width * 4));
  for (let y = 0; y < height; y++) {
    const row = y * (1 + width * 4);
    raw[row] = 0;
    for (let x = 0; x < width; x++) {
      const s = (y * width + x) * 4, d = row + 1 + x * 4;
      raw[d] = bgra[s + 2]; raw[d + 1] = bgra[s + 1]; raw[d + 2] = bgra[s]; raw[d + 3] = bgra[s + 3];
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

mkdirSync(join(ROOT, 'app', 'sprites'), { recursive: true });
writeFileSync(join(ROOT, 'app', 'sprites', 'dragon.png'), encodePngRgba(sheet, FW * 2, FH));

// ── procedural fluffy clouds (soft alpha, slight blue shade underneath) ──
function cloud(width, height, circles) {
  // canvas is tall enough that no circle clips; the underside flattens with a
  // SOFT fade (baseline) instead of a hard canvas cut
  const buf = new Uint8Array(width * height * 4);
  const baseline = height - 7;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      let best = 1e9;
      for (const [cx, cy, r] of circles) {
        const d = Math.hypot(x - cx, y - cy) / r;
        if (d < best) best = d;
      }
      if (best >= 1.02) continue;
      const i = (y * width + x) * 4;
      const soft = Math.min(1, (1.02 - best) * 3.2);
      let a = Math.round(255 * Math.pow(soft, 0.6));
      if (y > baseline) a = Math.round(a * Math.max(0, (height - y) / 7));
      if (a <= 0) continue;
      // bottoms shade toward sky blue for depth
      const shade = y > height * 0.55 ? 1 - (y / height - 0.55) * 0.8 : 1;
      const rC = Math.round(255 * shade + 205 * (1 - shade));
      const gC = Math.round(255 * shade + 220 * (1 - shade));
      const bC = 255;
      buf[i] = bC; buf[i + 1] = gC; buf[i + 2] = rC; buf[i + 3] = a;
    }
  }
  return { buf, width, height };
}
const c1 = cloud(64, 36, [[14, 19, 10], [27, 14, 12], [41, 16, 11], [52, 20, 9], [33, 22, 12]]);
const c2 = cloud(52, 32, [[12, 17, 9], [24, 12, 10], [36, 15, 10], [42, 19, 8], [24, 19, 11]]);
writeFileSync(join(ROOT, 'app', 'sprites', 'cloud1.png'), encodePngRgba(c1.buf, c1.width, c1.height));
writeFileSync(join(ROOT, 'app', 'sprites', 'cloud2.png'), encodePngRgba(c2.buf, c2.width, c2.height));

// ── pipe sprites: cylinder shading baked in (body column + capped end) ──
const PIPE_BASE = [46, 165, 78];
function pipeShade(t) {
  let m = 0.42 + 0.62 * Math.sin(Math.PI * (0.12 + 0.76 * t));
  return Math.min(1, m);
}
function pipeRow(buf, width, y, x0, x1, boost) {
  for (let x = x0; x < x1; x++) {
    const m = Math.min(1, pipeShade((x - x0 + 0.5) / (x1 - x0)) * boost);
    const i = (y * width + x) * 4;
    buf[i] = (PIPE_BASE[2] * m) | 0;      // B
    buf[i + 1] = (PIPE_BASE[1] * m) | 0;  // G
    buf[i + 2] = (PIPE_BASE[0] * m) | 0;  // R
    buf[i + 3] = 255;
  }
}
{ // body: 96x4, tiled/stretched vertically
  const w = 96, h = 4;
  const buf = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) pipeRow(buf, w, y, 0, w, 1.0);
  writeFileSync(join(ROOT, 'app', 'sprites', 'pipe_body.png'), encodePngRgba(buf, w, h));
}
{ // cap: 108x30 with dark lips top+bottom
  const w = 108, h = 30;
  const buf = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) pipeRow(buf, w, y, 0, w, 1.08);
  for (let y of [0, 1, 2, h - 3, h - 2, h - 1]) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      buf[i] = 40; buf[i + 1] = 82; buf[i + 2] = 22; buf[i + 3] = 255;
    }
  }
  writeFileSync(join(ROOT, 'app', 'sprites', 'pipe_cap.png'), encodePngRgba(buf, w, h));
}
{ // 1x1 white pixel: tintable translucent overlays in the sprite layer
  const buf = new Uint8Array([255, 255, 255, 255]);
  writeFileSync(join(ROOT, 'app', 'sprites', 'px.png'), encodePngRgba(buf, 1, 1));
}

// ── WAVs: mono s16 @ 48000 ───────────────────────────────────────────
function wav(samples) {
  const data = Buffer.alloc(samples.length * 2);
  samples.forEach((s, i) => data.writeInt16LE(Math.max(-32768, Math.min(32767, s | 0)), i * 2));
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(48000, 24); h.writeUInt32LE(96000, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}
const R = 48000;

// flap: 110ms square swoop 420 -> 180 Hz
{
  const n = (R * 0.11) | 0, out = new Array(n);
  let phase = 0;
  for (let i = 0; i < n; i++) {
    const f = 420 - (240 * i) / n;
    const env = 1 - i / n;
    out[i] = (phase % 1 < 0.5 ? 5200 : -5200) * env;
    phase += f / R;
  }
  writeFileSync(join(ROOT, 'app', 'sounds', 'flap.wav'), wav(out));
}
// score: two soft sine dings, 880 then 1318 Hz
{
  const seg = (R * 0.07) | 0, out = new Array(seg * 2);
  for (let i = 0; i < seg; i++) {
    out[i] = Math.sin((2 * Math.PI * 880 * i) / R) * 5200 * (1 - i / seg);
    out[seg + i] = Math.sin((2 * Math.PI * 1318 * i) / R) * 5200 * (1 - i / seg);
  }
  writeFileSync(join(ROOT, 'app', 'sounds', 'score.wav'), wav(out));
}
// hit: 220ms decaying noise thud
{
  const n = (R * 0.22) | 0, out = new Array(n);
  let lp = 0, seed = 0x12345678;
  for (let i = 0; i < n; i++) {
    seed = (seed * 1103515245 + 12345) >>> 0;
    const noise = ((seed >> 16) & 0x7fff) - 16384;
    lp = lp * 0.82 + noise * 0.18; // low-pass -> thud
    out[i] = lp * 0.9 * (1 - i / n);
  }
  writeFileSync(join(ROOT, 'app', 'sounds', 'hit.wav'), wav(out));
}
console.log('assets written: sprites/{dragon,cloud1,cloud2,pipe_body,pipe_cap,px}.png, sounds/{flap,score,hit}.wav');
