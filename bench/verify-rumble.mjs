// Verifies the engine's rumble surface end to end: Ruby (args.gtk.rumble /
// rumble_stop / rumble?) -> WC module functions -> the three env imports ->
// the host. Drives wasmcart's public CartHost API with a spying rumble
// handler; no host code is modified.
//
// The second half is the control: it re-runs with a handler that reports NO
// rumble. If both passes look identical the plumbing is dead, not working.
//
// Usage: node bench/verify-rumble.mjs [engine.wasm]
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

// A cart whose whole job is to exercise every rumble entry point and report
// what it saw through the debug slots the harness can read.
const CART_RB = `
def tick args
  s = args.state
  s.seen ||= 0
  if args.tick_count == 0
    s.seen = 1 if args.gtk.rumble?      # controller_one, 0-based pad 0
    s.seen += 2 if args.gtk.rumble?(1)
  end
  args.gtk.rumble 0.75, 0.25, 150         if args.tick_count == 1
  args.gtk.rumble 0.5, 0.5, 100, 1        if args.tick_count == 2
  args.gtk.rumble_stop                    if args.tick_count == 3
  args.gtk.rumble 5.0, -2.0, 999999       if args.tick_count == 4
  args.gtk.rumble 1.0, 1.0, 50, 99        if args.tick_count == 5
  args.gtk.debug_score = s.seen
  args.outputs.solids << [0, 0, 64, 64, 200, 40, 40]
end
`;

const work = mkdtempSync(join(tmpdir(), 'wy-rumble-'));
const appDir = join(work, 'app');
execFileSync('mkdir', ['-p', appDir]);
writeFileSync(join(appDir, 'main.rb'), CART_RB);
const cartPath = join(work, 'rumble.wasc');
execFileSync('node', [
  join(WASMCART_REPO, 'bin', 'wasmcart-pack.js'),
  '--wasm', enginePath, '--assets', appDir,
  '--name', 'rumble-verify', '--width', '1280', '--height', '720',
  '-o', cartPath,
], { stdio: 'ignore' });

const pads = [{ connected: true, buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0, leftTrigger: 0, rightTrigger: 0 }];

async function run(hasRumble) {
  const calls = [];
  const cart = new CartHost();
  await cart.load(cartPath);
  cart.setRumbleHandler({
    hasRumble: (padId) => hasRumble && padId === 0,
    rumble: (padId, low, high, durationMs) =>
      calls.push({ op: 'rumble', padId, low, high, durationMs }),
    stopRumble: (padId) => calls.push({ op: 'stop', padId }),
  });
  for (let i = 0; i < 8; i++) cart.runFrame(pads);
  const seen = Number(cart.readDebugValue('score').value);
  const rubyOk = Number(cart.readDebugValue('ruby_ok').value);
  cart.dispose?.();
  return { calls, seen, rubyOk };
}

const fails = [];
const check = (ok, msg) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${msg}`); if (!ok) fails.push(msg); };

const live = await run(true);
console.log('--- rumble-capable pad ---');
console.log(JSON.stringify(live.calls));
check(live.rubyOk === 1, 'cart ran without a Ruby exception');
check(live.seen === 1, `rumble? is per-pad: pad 0 yes, pad 1 no (score=${live.seen})`);

const r0 = live.calls[0];
check(r0 && r0.op === 'rumble' && r0.padId === 0 && Math.abs(r0.low - 0.75) < 1e-5
      && Math.abs(r0.high - 0.25) < 1e-5 && r0.durationMs === 150,
      'args.gtk.rumble low/high/ms reaches the host on pad 0');

const r1 = live.calls[1];
check(r1 && r1.op === 'rumble' && r1.padId === 1,
      'the 4th argument selects the controller (0-based)');

const r2 = live.calls[2];
check(r2 && r2.op === 'stop' && r2.padId === 0, 'args.gtk.rumble_stop reaches the host');

const r3 = live.calls[3];
check(r3 && r3.op === 'rumble' && r3.low >= 0 && r3.low <= 1 && r3.high >= 0 && r3.high <= 1
      && r3.durationMs <= 5000,
      'out-of-range levels and duration are clamped by the host');

check(live.calls.length === 4, `an out-of-range pad index is dropped (calls=${live.calls.length})`);

// Control: a pad reporting no rumble must change what the cart observes. If
// this pass matches the one above, nothing was ever really wired up.
const dead = await run(false);
console.log('--- pad with no rumble (control) ---');
check(dead.seen === 0, `rumble? reports false with no capability (score=${dead.seen})`);
check(dead.seen !== live.seen, 'the capability query actually moves between the two runs');

rmSync(work, { recursive: true, force: true });
console.log(fails.length ? `\n${fails.length} FAILED` : '\nall rumble checks passed');
process.exit(fails.length ? 1 : 0);
