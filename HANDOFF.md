# GL2D Renderer — Status: COMPLETE (2026-07-25)

## Outcome

The GL2D renderer is **the default build target** and is **2-14× faster than
the CPU rasterizer** with **pixel-identical output**. Commits: `c294ad2`
(renderer + draw_list + tooling), `e81873e` (CPU-frame blit fallback).

Isolated per-frame cost (real WebGL2, `bench/bench-cart.mjs`, 2000-frame avg):

| Cart | GL2D | GL2D + glFinish | CPU build |
|---|---|---|---|
| Blocks | 0.57 ms | 0.90 ms | 1.36 ms |
| Wyvern | 0.15 ms | 0.46 ms | 2.18 ms |

Microbenches (`bench/carts/`): 1000 rects marshal+render 0.088 ms (~88 ns/rect);
300 sprites GL 0.29 ms vs CPU 8.09 ms (28×); empty-tick floor 0.02 ms.
Remaining game frame time is ~85% the game's own mruby tick logic
(`mrb_vm_exec`), not the renderer.

Pixel parity: lockstep seeded A/B runs (`bench/compare-render.mjs`) show
**0.000% differing pixels** over 1100 frames on Blocks, Wyvern, and the
render-target test cart (max channel delta ≤4 = GL float rounding; the
render-target cart is bit-exact).

## Why it ever looked slow (important for future measurements)

romdev's `WasmcartHost.stepFrames` does a ~2.5 ms 720p `glReadPixels` +
copies once per call, and the playtest window calls it once per tick — so
playtest `perf.stepMs` charges that readback to GL carts only. The cart
renderer was never slower. Rules of thumb:

- Playtest `stepMs` is NOT a fair GL-vs-CPU comparison. Use
  `bench/bench-cart.mjs` (drives wasmcart's public `CartHost` API with the
  same offscreen webgl-node context; no host code involved).
- Bulk `frame({op:'step', frames:N})` pays readback once per call — fine.
- The real SDL player (`wasmcart-play` windowed) creates the WebGL2 context
  directly on the native window: no readback at all in production.
- Fixing playtest accounting would be an upstream romdev change (async PBO
  readback, or readback outside the stepMs window).

## Architecture (runtime/render2d_gl.c + runtime.c + prelude.rb)

- GLSL ES 3.00 program, shared 2048² RGBA atlas (GL_NEAREST — matches the
  CPU rasterizer's point sampling; this is what makes sprites pixel-equal),
  indexed quad batching for solids and sprites, cached blend/texture/uniform
  state, VAO with all immutable setup hoisted to init. Blocks renders in ONE
  draw call, Wyvern in three.
- `WC.draw_list(list, kind)` (kinds: 0 solid, 1 border, 2 line, 3 label,
  4 sprite): walks whole outputs lists in C. Arrays take a positional fast
  path, hashes a keyed path via boot-interned symbols, anything else falls
  back to the Ruby `__wc_draw_*` shim. The prelude flush calls it for
  solids/sprites/labels/lines/borders; `primitives`/`debug` stay in Ruby.
- **CPU fallback**: GL is a host requirement (every wasmcart/romdev host
  provides a WebGL2 context), so the only fallback that matters is
  feature-level: CPU-only features (render targets, TTF labels, `@rt:`
  sprites, exception banner) call `wy_r2d_disable()` → sticky `cpu_mode`:
  frames CPU-rasterize into the cart framebuffer and `wy_r2d_end` blits it
  to GL via `wc_gl_blit` (bit-exact with the CPU build; costs CPU-build
  speed + one texture upload). Before `e81873e` such carts showed only the
  clear color — this was the one blocker to defaulting gl2d. (If GL init
  ever fails anyway, `wy_r2d_active()` stays false and draws fall through
  to the CPU rasterizer — defensive, not a supported configuration.)
- Debug counters (read via `wasm({op:'debugState'})`): `gl_draws`,
  `gl_solid_flushes`, `gl_tex_flushes`, `gl_quads`, `gl_upload_bytes`, plus
  a `dt_*` frame-time probe (only meaningful under a non-fixed-step host;
  romdev always runs the fixed 16.666 ms virtual clock).

## Build & test

```sh
cd <your>/wasmcart-mruby
# build.sh defaults WASMCART_REPO to the sibling ../../wasmcart checkout.
# Only set it if yours lives somewhere else:
#   export WASMCART_REPO=/path/to/wasmcart
./runtime/build.sh          # default = gl2d → build/main.wasm + flappy-wyvern.wasc
./runtime/build.sh cpu      # benchmark comparator → build/main-cpu.wasm

# pack a cart
node $WASMCART_REPO/bin/wasmcart-pack.js --wasm build/main.wasm \
  --assets examples/blocks/app --name blocks-2dgl -o build/blocks-2dgl.wasc

# perf (isolated, no romdev)
node bench/bench-cart.mjs build/blocks-2dgl.wasc 2000

# pixel parity GL vs CPU (lockstep, seeded, scripted input)
node bench/compare-render.mjs build/blocks-2dgl.wasc build/blocks-cpu.wasc 300

# visual/regression check in romdev (needs romdev >= 0.106.1 for real GL;
# confirm catalog status reports gl:"rendered")
# loadMedia platform:wasmcart deterministicSeed:7 → step → frame verify
```

mruby cross-build stays at `-Os`: -O2/-O3 measured equal or worse (the VM
is dispatch-bound). Rebuild mruby by deleting
`runtime/vendor/mruby/build/emscripten`. Known harmless warning:
stb_vorbis pointer-comparison tautology.

## Dead ends (do not retry without new evidence)

- `glBufferSubData` instead of `glBufferData`: regressed on real GL.
- Instanced solid rendering: translucent striping, no gain.
- mruby at -O2/-O3: no gain over -Os.
- The retained `WC.static_solid_batch` path exists but is unused by the
  examples (black-frame history; batching made it unnecessary).

## What could still be faster (all outside the renderer)

- Game-side Ruby tick logic (Blocks board loops) — app code.
- mruby VM itself (dispatch-bound interpreter).
- romdev playtest readback accounting — upstream host change.
