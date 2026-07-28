// A/B render comparison: run the GL cart and the CPU cart in lockstep with
// the same deterministic seed and input script, snapshot frames at chosen
// points, and pixel-diff them (RGB, small tolerance for GL float rounding).
//
// Usage: node bench/compare-render.mjs <gl.wasc> <cpu.wasc> [pressStartAt]
import { existsSync, mkdirSync } from 'node:fs';
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
const { CartHost, BUTTON } = await import(join(WASMCART_REPO, 'index.js'));

// webgl-node lives in the wasmcart checkout's node_modules; allow an override
// for a checkout that installs it elsewhere.
const WEBGL_NODE = process.env.WEBGL_NODE
  || join(WASMCART_REPO, 'node_modules', 'webgl-node', 'index.mjs');
import { writeFileSync } from 'node:fs';

const glPath = process.argv[2], cpuPath = process.argv[3];
const pressStartAt = Number(process.argv[4] ?? 300);
const CHECK_FRAMES = [120, 260, 420, 700, 1100];
const W = 1280, H = 720;

let gl = null;
async function glFactory() {
  const wn = await import(WEBGL_NODE);
  gl = wn.createWebGL2Context(W, H).gl;
  return gl;
}

async function loadCart(path, useGl) {
  const cart = new CartHost();
  await cart.load(path, {
    ...(useGl ? { glBackend: glFactory } : {}),
    deterministic: { seed: 7 },
  });
  return cart;
}

const idle = { connected: true, buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0, leftTrigger: 0, rightTrigger: 0 };
function padsAt(frame) {
  // press START for 3 frames at pressStartAt, and A (flap/drop) briefly later
  if (frame >= pressStartAt && frame < pressStartAt + 3) return [{ ...idle, buttons: BUTTON.START }];
  if (frame >= pressStartAt + 200 && frame < pressStartAt + 203) return [{ ...idle, buttons: BUTTON.A }];
  return [idle];
}

// CPU cart: XRGB8888 u32 → RGB bytes (memory order [B,G,R,X] LE), row 0 = top.
function rgbFromCpu(fb) {
  const out = new Uint8Array(W * H * 3);
  for (let i = 0, o = 0; i < W * H; i++, o += 3) {
    out[o] = fb[i * 4 + 2]; out[o + 1] = fb[i * 4 + 1]; out[o + 2] = fb[i * 4];
  }
  return out;
}

// GL: readPixels bottom-up RGBA → top-down RGB.
function rgbFromGl() {
  const raw = new Uint8Array(W * H * 4);
  gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, raw);
  const out = new Uint8Array(W * H * 3);
  for (let y = 0; y < H; y++) {
    const src = (H - 1 - y) * W * 4, dst = y * W * 3;
    for (let x = 0; x < W; x++) {
      out[dst + x * 3] = raw[src + x * 4];
      out[dst + x * 3 + 1] = raw[src + x * 4 + 1];
      out[dst + x * 3 + 2] = raw[src + x * 4 + 2];
    }
  }
  return out;
}

function diff(a, b, tol) {
  let differing = 0, maxDiff = 0, sumDiff = 0;
  const heat = new Uint8Array(W * H); // per-pixel max channel delta
  for (let i = 0, p = 0; i < a.length; i += 3, p++) {
    const d = Math.max(Math.abs(a[i] - b[i]), Math.abs(a[i + 1] - b[i + 1]), Math.abs(a[i + 2] - b[i + 2]));
    heat[p] = d;
    if (d > tol) differing++;
    if (d > maxDiff) maxDiff = d;
    sumDiff += d;
  }
  return { differing, pct: 100 * differing / (W * H), maxDiff, meanDiff: sumDiff / (W * H), heat };
}

function writePpm(path, rgb) {
  const header = Buffer.from(`P6\n${W} ${H}\n255\n`);
  writeFileSync(path, Buffer.concat([header, Buffer.from(rgb)]));
}

const glCart = await loadCart(glPath, true);
const cpuCart = await loadCart(cpuPath, false);

let frame = 0;
let worst = { pct: -1 };
for (const target of CHECK_FRAMES) {
  let cpuFb = null;
  while (frame < target) {
    const pads = padsAt(frame);
    glCart.runFrame(pads);
    cpuFb = cpuCart.runFrame(pads).framebuffer;
    frame++;
  }
  const a = rgbFromGl();
  const b = rgbFromCpu(cpuFb);
  const d = diff(a, b, 8);
  console.log(`frame ${String(target).padStart(4)}: ${d.pct.toFixed(3)}% pixels differ (>8/255), max ${d.maxDiff}, mean ${d.meanDiff.toFixed(3)}`);
  if (d.pct > worst.pct) worst = { ...d, frame: target, a, b };
}

// dump the worst frame pair + heatmap for inspection. Anchor to the script's
// own directory: a cwd-relative path only works when run from the repo root,
// and the directory may not exist in a fresh checkout.
const PROF_DIR = join(HERE, 'prof');
mkdirSync(PROF_DIR, { recursive: true });
const base = process.argv[2].replace(/.*\//, '').replace('.wasc', '');
writePpm(join(PROF_DIR, `${base}-gl-f${worst.frame}.ppm`), worst.a);
writePpm(join(PROF_DIR, `${base}-cpu-f${worst.frame}.ppm`), worst.b);
const heatRgb = new Uint8Array(W * H * 3);
for (let p = 0; p < W * H; p++) {
  const v = worst.heat[p] > 8 ? 255 : worst.heat[p] * 8;
  heatRgb[p * 3] = v; heatRgb[p * 3 + 1] = worst.heat[p] > 8 ? 0 : v; heatRgb[p * 3 + 2] = worst.heat[p] > 8 ? 0 : v;
}
writePpm(join(PROF_DIR, `${base}-diff-f${worst.frame}.ppm`), heatRgb);
console.log(`worst frame ${worst.frame} dumped to ${PROF_DIR}/${base}-{gl,cpu,diff}-f${worst.frame}.ppm`);
process.exit(0);
