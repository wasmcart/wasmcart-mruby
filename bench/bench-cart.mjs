// Benchmark harness: drives wasmcart's public CartHost API to time a cart's
// per-frame cost in isolation, then times the romdev-style GL readback
// separately. No host code is modified — this is a consumer of the library.
//
// Usage: node bench/bench-cart.mjs <cart.wasc> [frames]
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Resolve the wasmcart checkout the same way runtime/build.sh does:
// WASMCART_REPO if set, else the sibling checkout. Absolute paths to one
// developer's home directory do not survive a second machine.
const HERE = dirname(fileURLToPath(import.meta.url));
const WASMCART_REPO = resolve(process.env.WASMCART_REPO || join(HERE, '..', '..', 'wasmcart'));
if (!existsSync(join(WASMCART_REPO, 'index.js'))) {
  console.error(`wasmcart checkout not found at ${WASMCART_REPO}`);
  console.error('set WASMCART_REPO=/path/to/wasmcart');
  process.exit(2);
}
const { CartHost } = await import(join(WASMCART_REPO, 'index.js'));

// webgl-node lives in the wasmcart checkout's node_modules; allow an override
// for a checkout that installs it elsewhere.
const WEBGL_NODE = process.env.WEBGL_NODE
  || join(WASMCART_REPO, 'node_modules', 'webgl-node', 'index.mjs');

const cartPath = process.argv[2];
const FRAMES = Number(process.argv[3] || 1000);
if (!cartPath) { console.error('usage: bench-cart.mjs <cart.wasc> [frames]'); process.exit(2); }

// Same offscreen context setup as romdev's WasmcartHost (720p ceiling).
let gl = null;
async function glFactory() {
  const wn = await import(WEBGL_NODE);
  gl = wn.createWebGL2Context(1280, 720).gl;
  return gl;
}

const cart = new CartHost();
await cart.load(cartPath, { glBackend: glFactory });
if (typeof cart.setFixedStep === 'function') cart.setFixedStep(1000 / 60);

const pads = [{ connected: true, buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0, leftTrigger: 0, rightTrigger: 0 }];

// Warm up: JIT, sprite decode, atlas upload, mruby heap growth.
for (let i = 0; i < 180; i++) cart.runFrame(pads);

// ── 1. pure per-frame step cost (what the cart+wasm actually costs) ──
const t0 = performance.now();
for (let i = 0; i < FRAMES; i++) cart.runFrame(pads);
const stepMs = (performance.now() - t0) / FRAMES;

// ── 1b. step + glFinish: full CPU+GPU per-frame cost, nothing deferred ──
let stepFinishMs = null;
if (gl && cart.usesGL) {
  const tf = performance.now();
  for (let i = 0; i < FRAMES; i++) { cart.runFrame(pads); gl.finish(); }
  stepFinishMs = (performance.now() - tf) / FRAMES;
}

// ── 2. romdev-style GL readback cost (per call), only for GL carts ──
let readbackMs = null;
if (gl && cart.usesGL) {
  const w = 1280, h = 720, row = w * 4;
  const N = 60;
  const tr = performance.now();
  for (let i = 0; i < N; i++) {
    cart.runFrame(pads);
    const raw = new Uint8Array(w * h * 4);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw);
    const flipped = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) flipped.set(raw.subarray((h - 1 - y) * row, (h - y) * row), y * row);
    for (let i2 = 3; i2 < flipped.length; i2 += 4) flipped[i2] = 0xff;
  }
  readbackMs = (performance.now() - tr) / N - stepMs;
}

// ── 3. framebuffer copy cost the playtest loop pays for CPU carts ──
let fbCopyMs = null;
{
  const r = cart.runFrame(pads);
  const N = 120;
  const tc = performance.now();
  for (let i = 0; i < N; i++) { const c = new Uint8Array(r.framebuffer); if (c[0] === 255) process.stdout.write(''); }
  fbCopyMs = (performance.now() - tc) / N;
}

console.log(JSON.stringify({
  cart: cartPath.split('/').pop(),
  usesGL: !!cart.usesGL,
  glRendered: !!gl,
  frames: FRAMES,
  stepMsPerFrame: +stepMs.toFixed(3),
  stepFinishMsPerFrame: stepFinishMs === null ? null : +stepFinishMs.toFixed(3),
  readbackMsPerCall: readbackMs === null ? null : +readbackMs.toFixed(3),
  fbCopyMs: +fbCopyMs.toFixed(3),
}, null, 2));
process.exit(0);
