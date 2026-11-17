// Runs every end-to-end check against both engine builds, plus the vendored
// header drift check. Exits 1 if any check fails, so it is the release gate.
//
// Usage: node bench/verify-all.mjs
// Needs a wasmcart checkout (WASMCART_REPO, default ../wasmcart) and the
// engines built (runtime/build.sh and runtime/build.sh cpu).
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');
const env = { ...process.env, WASMCART_REPO: resolve(process.env.WASMCART_REPO || join(REPO, '..', 'wasmcart')) };

const engines = ['build/main.wasm', 'build/main-cpu.wasm'].map((p) => join(REPO, p));
for (const e of engines) {
  if (!existsSync(e)) {
    console.error(`missing ${e}: run runtime/build.sh (and runtime/build.sh cpu)`);
    process.exit(2);
  }
}

const runs = [
  ['abi-drift', [join(REPO, 'tools', 'abi-drift.mjs')]],
  ...engines.flatMap((e) => [
    [`clock  ${e.slice(REPO.length + 1)}`, [join(HERE, 'verify-clock.mjs'), e]],
    [`rumble ${e.slice(REPO.length + 1)}`, [join(HERE, 'verify-rumble.mjs'), e]],
  ]),
  ['net', [join(HERE, 'verify-net.mjs')]],
];

const failed = [];
for (const [name, args] of runs) {
  const r = spawnSync(process.execPath, args, { env, encoding: 'utf8' });
  const ok = r.status === 0;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}`);
  if (!ok) {
    failed.push(name);
    process.stdout.write(r.stdout + r.stderr);
  }
}
console.log(failed.length ? `\n${failed.length} FAILED: ${failed.join(', ')}` : '\nall checks passed');
process.exit(failed.length ? 1 : 0);
