// Verifies the engine's peer-networking surface end to end against a REAL
// WebSocket server: Ruby (args.net.* / def net_message) -> the WC module
// functions -> the nine wc_peer_* imports and the four wc_peer_on_* exports
// -> wasmcart's public CartHost -> a live socket.
//
// The server is wasmcart's own test/wsserver.mjs, started as a child process.
// Its /echo endpoint returns whatever the cart sends, /relay/<room> forwards
// between two carts (that is what a data channel looks like from inside a
// cart), and /drop accepts then closes so the error/disconnect path is real
// rather than simulated.
//
// The last section is the CONTROL: it re-runs the echo case with a manifest
// that grants no net reach. If both passes look identical the plumbing is
// dead, not working.
//
// Usage: node bench/verify-net.mjs [engine.wasm]
import { existsSync, mkdtempSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawn } from 'node:child_process';

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

const PORT = 8791;
const HOST = '127.0.0.1';

// ── the test carts ───────────────────────────────────────────────────
//
// Everything a cart observes is reported through the two debug slots the
// harness can read (score/aux), plus WC.log lines for the payload trace.

// Dials /echo, sends a payload containing embedded NUL bytes and a byte with
// the high bit set (so a UTF-8 round trip would corrupt it), and reports what
// came back.
const ECHO_RB = `
# Embedded NULs and a 0xFF byte: a payload that only survives if the whole
# path carries explicit lengths and never treats bytes as text.
PAYLOAD = "A\\x00B\\xFF\\x00\\x00z"

def net_connected args, peer, name
  args.state.connected = peer
  args.state.peer_name = name
  args.net.send peer, PAYLOAD
end

def net_message args, peer, data
  args.state.got = data
  args.state.got_peer = peer
end

def net_error args, peer
  args.state.errors = (args.state.errors || 0) + 1
end

def net_disconnected args, peer
  args.state.disconnects = (args.state.disconnects || 0) + 1
end

def tick args
  s = args.state
  if args.tick_count == 0
    s.opened = args.net.open('ws://${HOST}:${PORT}/echo')
    s.opened_bad = args.net.open('ws://evil.example.com/echo')
  end

  # score encodes, in order: opened ok, connect fired, bytes matched,
  # peer id agreed between the callback and open, and one live peer listed.
  score = 0
  score |= 1  if s.opened
  score |= 2  if s.connected
  score |= 4  if s.got == PAYLOAD
  score |= 8  if s.got_peer == s.opened
  score |= 16 if args.net.peers.include?(s.opened)
  score |= 32 if args.net.state(s.opened) == :open
  score |= 64 if s.opened_bad.nil?
  score |= 128 if s.peer_name.is_a?(String)
  args.gtk.debug_score = score
  args.gtk.debug_aux = (s.got ? s.got.bytesize : -1)

  args.outputs.solids << [0, 0, 64, 64, 40, 200, 40]
end
`;

// Joins /relay/<room>. Two instances of this cart in the same room talk to
// each other, which is the shape the ABI is really for.
const RELAY_RB = (tag) => `
def net_connected args, peer, name
  args.state.peer = peer
  args.net.broadcast '${tag}-hello'
end

def net_message args, peer, data
  args.state.heard = data
end

def tick args
  s = args.state
  s.opened = args.net.open('ws://${HOST}:${PORT}/relay/room1') if args.tick_count == 0
  score = 0
  score |= 1 if s.peer
  score |= 2 if s.heard && s.heard != '${tag}-hello'
  score |= 4 if s.heard.to_s.end_with?('-hello')
  args.gtk.debug_score = score
  args.outputs.solids << [0, 0, 64, 64, 40, 40, 200]
end
`;

// Connects to /drop, which accepts the handshake then closes at once.
const DROP_RB = `
def net_disconnected args, peer
  args.state.closed = peer
end

def net_error args, peer
  args.state.errored = true
end

def tick args
  s = args.state
  s.opened = args.net.open('ws://${HOST}:${PORT}/drop') if args.tick_count == 0
  score = 0
  score |= 1 if s.closed
  score |= 2 if s.closed == s.opened
  score |= 4 if args.net.state(s.opened) == :closed
  args.gtk.debug_score = score
  args.outputs.solids << [0, 0, 64, 64, 200, 200, 40]
end
`;

// ── harness ──────────────────────────────────────────────────────────

const work = mkdtempSync(join(tmpdir(), 'wy-net-'));
const pads = [{ connected: true, buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0, leftTrigger: 0, rightTrigger: 0 }];

/** Pack a cart from Ruby source, granting the given domains in manifest.net. */
function packCart(name, ruby, domains) {
  const appDir = join(work, name, 'app');
  mkdirSync(appDir, { recursive: true });
  writeFileSync(join(appDir, 'main.rb'), ruby);
  const cartPath = join(work, `${name}.wasc`);
  const wsFlags = domains.flatMap((d) => ['--ws', d]);
  execFileSync('node', [
    join(WASMCART_REPO, 'bin', 'wasmcart-pack.js'),
    '--wasm', enginePath, '--assets', appDir,
    '--name', name, '--width', '1280', '--height', '720',
    ...wsFlags, '-o', cartPath,
  ], { stdio: 'ignore' });
  return cartPath;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Run a cart for a while, letting the event loop turn so sockets progress. */
async function runCart(cartPath, ticks = 40) {
  const cart = new CartHost();
  await cart.load(cartPath);
  for (let i = 0; i < ticks; i++) {
    cart.runFrame(pads);
    await sleep(10);   // real sockets need real time
  }
  const out = {
    score: Number(cart.readDebugValue('score').value),
    aux: Number(cart.readDebugValue('aux').value),
    rubyOk: Number(cart.readDebugValue('ruby_ok').value),
    wantsNet: cart.getInfo().wantsNet,
  };
  cart.destroy?.();
  return out;
}

const fails = [];
const check = (ok, msg) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${msg}`); if (!ok) fails.push(msg); };

// Start wasmcart's own test server and wait for its ready line.
const server = spawn('node', [join(WASMCART_REPO, 'test', 'wsserver.mjs'), '--port', String(PORT)], {
  stdio: ['ignore', 'pipe', 'inherit'],
});
await new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error('wsserver did not start')), 5000);
  server.stdout.on('data', (d) => {
    if (d.toString().includes('listening')) { clearTimeout(t); resolve(); }
  });
});

try {
  // ── echo: a real round trip, with a payload UTF-8 would ruin ──────
  console.log('--- echo (live socket) ---');
  const echo = await runCart(packCart('echo', ECHO_RB, [HOST]));
  check(echo.rubyOk === 1, 'cart ran without a Ruby exception');
  check(echo.wantsNet === true, 'the engine declares WC_FLAG_NET_PEER');
  check((echo.score & 1) !== 0, 'args.net.open returned a peer id');
  check((echo.score & 2) !== 0, 'net_connected fired for the dialed peer');
  check((echo.score & 4) !== 0,
        'the echoed bytes match exactly, embedded NULs and 0xFF included');
  check(echo.aux === 7, `the payload kept its length across the boundary (aux=${echo.aux})`);
  check((echo.score & 8) !== 0, 'the callback peer id is the one open returned');
  check((echo.score & 16) !== 0, 'args.net.peers lists the live peer');
  check((echo.score & 32) !== 0, 'args.net.state reports :open');
  check((echo.score & 64) !== 0, 'a domain outside manifest.net.domains is refused');
  check((echo.score & 128) !== 0, 'args.net gives the peer a display name String');

  // ── relay: two carts, no shared memory, forwarded frames ──────────
  console.log('--- relay between two carts ---');
  const aPath = packCart('relay-a', RELAY_RB('a'), [HOST]);
  const bPath = packCart('relay-b', RELAY_RB('b'), [HOST]);
  const [relayA, relayB] = await Promise.all([runCart(aPath, 60), runCart(bPath, 60)]);
  check(relayA.rubyOk === 1 && relayB.rubyOk === 1, 'both relay carts ran clean');
  check((relayA.score & 1) !== 0 && (relayB.score & 1) !== 0, 'both carts connected');
  check((relayA.score & 2) !== 0 || (relayB.score & 2) !== 0,
        'a broadcast from one cart reached the other');
  check((relayA.score & 4) !== 0 || (relayB.score & 4) !== 0,
        'the forwarded payload arrived intact');

  // ── drop: the server closes, the cart must hear about it ──────────
  console.log('--- server closes the connection ---');
  const drop = await runCart(packCart('drop', DROP_RB, [HOST]), 40);
  check(drop.rubyOk === 1, 'drop cart ran clean');
  check((drop.score & 1) !== 0, 'net_disconnected fired');
  check((drop.score & 2) !== 0, 'the disconnect carries the right peer id');
  check((drop.score & 4) !== 0, 'args.net.state reports :closed afterwards');

  // ── CONTROL: no manifest grant, so nothing must work ──────────────
  //
  // The cart wasm is identical and the server is still up. If this scores the
  // same as the live run, the test is measuring nothing.
  console.log('--- control: manifest grants no domains ---');
  const denied = await runCart(packCart('denied', ECHO_RB, []));
  check(denied.rubyOk === 1, 'denied cart still runs (a refused open is not fatal)');
  check((denied.score & 1) === 0, 'args.net.open returns nil with no manifest grant');
  check((denied.score & 4) === 0, 'no bytes round-trip with no manifest grant');
  check(denied.score !== echo.score,
        `the control scores differently from the live run (${denied.score} vs ${echo.score})`);
} finally {
  server.kill();
  rmSync(work, { recursive: true, force: true });
}

console.log(fails.length ? `\n${fails.length} FAILED` : '\nall peer networking checks passed');
process.exit(fails.length ? 1 : 0);
