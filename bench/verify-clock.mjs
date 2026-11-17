// Verifies the frame clock surface end to end: the host's wc_time ->
// WC.delta_ms / WC.time_ms -> args.gtk.delta_ms / args.gtk.time_ms in Ruby.
// Drives wasmcart's public CartHost API; no host code is modified.
//
// Two runs, each a control for the other:
//   - deterministic clock (seed 7): every delta is the fixed step (16.667 ms)
//     and time_ms advances by exactly that step per tick.
//   - real clock with a 40 ms wait between frames: deltas near 40 ms, which a
//     constant or a tick count wearing a clock's name could not produce.
//
// Usage: node bench/verify-clock.mjs [engine.wasm]
import { existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');
const WASMCART_REPO = resolve(process.env.WASMCART_REPO || join(REPO, '..', 'wasmcart'));
if (!existsSync(join(WASMCART_REPO, 'index.js'))) {
  console.error(`wasmcart checkout not found at ${WASMCART_REPO}`);
  console.error('set WASMCART_REPO=/path/to/wasmcart');
  process.exit(2);
}
const { CartHost } = await import(join(WASMCART_REPO, 'index.js'));

const enginePath = resolve(process.argv[2] || join(REPO, 'build', 'main.wasm'));
if (!existsSync(enginePath)) {
  console.error(`engine wasm not found: ${enginePath} (run runtime/build.sh)`);
  process.exit(2);
}

// score = delta_ms in microseconds, aux = time_ms in microseconds.
const CART_RB = `
def tick args
  args.gtk.debug_score = (args.gtk.delta_ms * 1000).round
  args.gtk.debug_aux   = (args.gtk.time_ms * 1000).round
  args.outputs.solids << [0, 0, 64, 64, 40, 200, 40]
end
`;

const work = mkdtempSync(join(tmpdir(), 'wy-clock-'));
const appDir = join(work, 'app');
execFileSync('mkdir', ['-p', appDir]);
writeFileSync(join(appDir, 'main.rb'), CART_RB);
const cartPath = join(work, 'clock.wasc');
execFileSync('node', [
  join(WASMCART_REPO, 'bin', 'wasmcart-pack.js'),
  '--wasm', enginePath, '--assets', appDir,
  '--name', 'clock-verify', '--width', '1280', '--height', '720',
  '-o', cartPath,
], { stdio: 'ignore' });

const pads = [{ connected: true, buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0, leftTrigger: 0, rightTrigger: 0 }];
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function run(options, gapMs) {
  const cart = new CartHost();
  await cart.load(cartPath, options);
  const samples = [];
  for (let i = 0; i < 10; i++) {
    if (gapMs) await wait(gapMs);
    cart.runFrame(pads);
    samples.push({
      delta: Number(cart.readDebugValue('score').value) / 1000,
      time: Number(cart.readDebugValue('aux').value) / 1000,
    });
  }
  const rubyOk = Number(cart.readDebugValue('ruby_ok').value);
  cart.dispose?.();
  return { samples, rubyOk };
}

const fails = [];
const check = (ok, msg) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${msg}`); if (!ok) fails.push(msg); };
const fmt = (xs) => xs.map((x) => x.toFixed(3)).join(' ');

const det = await run({ deterministic: { seed: 7 } }, 0);
console.log('--- deterministic clock (seed 7) ---');
console.log('delta_ms', fmt(det.samples.map((s) => s.delta)));
console.log('time_ms ', fmt(det.samples.map((s) => s.time)));
check(det.rubyOk === 1, 'cart ran without a Ruby exception');
check(det.samples.every((s) => Math.abs(s.delta - 1000 / 60) < 0.002),
  'every delta_ms is the fixed 16.667 ms step');
check(det.samples.slice(1).every((s, i) => Math.abs(s.time - det.samples[i].time - 1000 / 60) < 0.002),
  'time_ms advances by exactly one step per tick');

const real = await run({}, 40);
console.log('--- real clock, 40 ms between frames ---');
console.log('delta_ms', fmt(real.samples.map((s) => s.delta)));
console.log('time_ms ', fmt(real.samples.map((s) => s.time)));
check(real.rubyOk === 1, 'cart ran without a Ruby exception');
const later = real.samples.slice(1);
check(later.every((s) => s.delta >= 35 && s.delta <= 250),
  'delta_ms reports the real frame gap (35..250 ms, host clamp is 250)');
check(later.every((s, i) => s.time > real.samples[i].time),
  'time_ms keeps increasing');
check(Math.abs(later[later.length - 1].delta - det.samples[9].delta) > 10,
  'the two clocks disagree, so the value is the host clock and not a constant');

rmSync(work, { recursive: true, force: true });
console.log(fails.length ? `\n${fails.length} FAILED` : '\nall clock checks passed');
process.exit(fails.length ? 1 : 0);
