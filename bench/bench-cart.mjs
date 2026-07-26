// Benchmark harness: drives wasmcart's public CartHost API to time a cart's
// per-frame cost in isolation, then times the romdev-style GL readback
// separately. No host code is modified — this is a consumer of the library.
//
// Usage: node bench/bench-cart.mjs <cart.wasc> [frames]
import { CartHost } from '/Users/monteslu/code/cliemu/wasmcart/index.js';

const cartPath = process.argv[2];
const FRAMES = Number(process.argv[3] || 1000);
if (!cartPath) { console.error('usage: bench-cart.mjs <cart.wasc> [frames]'); process.exit(2); }

// Same offscreen context setup as romdev's WasmcartHost (720p ceiling).
let gl = null;
async function glFactory() {
  const wn = await import('/Users/monteslu/code/cliemu/wasmcart/node_modules/webgl-node/index.mjs');
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
