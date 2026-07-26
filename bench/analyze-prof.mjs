// Summarize a V8 .cpuprofile: self time per function, top N.
import { readFileSync } from 'node:fs';
const prof = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const topN = Number(process.argv[3] || 40);

const nodes = new Map(prof.nodes.map(n => [n.id, n]));
const self = new Map();
for (let i = 0; i < prof.samples.length; i++) {
  const id = prof.samples[i];
  const dt = prof.timeDeltas[i] || 0;
  self.set(id, (self.get(id) || 0) + dt);
}
const rows = [];
for (const [id, us] of self) {
  const n = nodes.get(id);
  if (!n) continue;
  const f = n.callFrame;
  rows.push({ name: f.functionName || '(anon)', url: (f.url || '').split('/').pop(), us });
}
// merge by name
const merged = new Map();
for (const r of rows) {
  const key = r.name + ' @' + r.url;
  merged.set(key, (merged.get(key) || 0) + r.us);
}
const total = [...merged.values()].reduce((a, b) => a + b, 0);
const sorted = [...merged.entries()].sort((a, b) => b[1] - a[1]).slice(0, topN);
console.log(`total sampled: ${(total / 1000).toFixed(0)} ms`);
for (const [k, us] of sorted) {
  console.log(`${(us / 1000).toFixed(1).padStart(8)} ms  ${(100 * us / total).toFixed(1).padStart(5)}%  ${k}`);
}
