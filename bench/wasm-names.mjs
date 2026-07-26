// Print function names for given indices from a .wasm name section.
import { readFileSync } from 'node:fs';
const buf = readFileSync(process.argv[2]);
const want = new Set(process.argv.slice(3).map(Number));
const mod = new WebAssembly.Module(buf);
const sections = WebAssembly.Module.customSections(mod, 'name');
if (!sections.length) { console.log('no name section'); process.exit(1); }
const view = new DataView(sections[0]);
const bytes = new Uint8Array(sections[0]);
let p = 0;
function leb() { let r = 0, s = 0, b; do { b = bytes[p++]; r |= (b & 127) << s; s += 7; } while (b & 128); return r >>> 0; }
function str(n) { const s = new TextDecoder().decode(bytes.subarray(p, p + n)); p += n; return s; }
while (p < bytes.length) {
  const id = bytes[p++];
  const size = leb();
  const end = p + size;
  if (id === 1) { // function names
    const count = leb();
    for (let i = 0; i < count; i++) {
      const idx = leb();
      const len = leb();
      const name = str(len);
      if (!want.size || want.has(idx)) console.log(idx, name);
    }
  }
  p = end;
}
