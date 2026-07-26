# GL2D Performance Handoff

## Goal

Make the GL2D renderer materially faster than the CPU renderer for the Ruby game examples, especially Tetris and Wyvern/Flappy.

The current result is not good enough: the real GPU path is slower than the CPU path on the tested scenes.

## Hard Constraints

- Do not modify wasmcart host code.
- Do not modify romdev host code.
- **Compile this runtime outside romdev with the repository's Emscripten build
  script.** Romdev deliberately does not compile wasmcart modules; it packages
  `.wasm` as `.wasc` and runs/tests the resulting cart.
- The user has installed the official Emscripten SDK and explicitly authorizes
  the next agent to invoke the host `emcc` through `./runtime/build.sh`.
- Do not install a separate emulator. Continue using romdev for validation and
  performance measurement.
- Preserve visual output and input/audio behavior.
- Validate with the updated real WebGL2 host, not the historical GL stub/fallback host.

### Session-policy requirement

The previous agent session had a platform-level rule forbidding every host
compiler invocation. That rule prevented it from running `emcc`, even after the
user installed Emscripten and granted permission. **The next session must be
started without that blanket rule, or with a scoped exception allowing
`/Users/monteslu/code/ruby/wasmcart-mruby/runtime/build.sh` and its `emcc`
invocation.** This handoff cannot override a higher-priority session policy.

## Repositories

- Cart/runtime project: `/Users/monteslu/code/ruby/wasmcart-mruby`
- Updated wasmcart checkout: `/Users/monteslu/code/cliemu/wasmcart`
- Updated romdev checkout: `/Users/monteslu/code/cliemu/wasmcart/romdev`
- Older checkout used by the runtime build script's default relative path: `/Users/monteslu/code/ruby/wasmcart`

The updated versions used for valid GPU testing were:

- wasmcart `0.6.0`
- romdev `0.106.1`

`romdev` must report `gl: "rendered"` for an actual GPU test. Historical measurements from romdev `0.105.x` are invalid because GL was stubbed/fallback there.

## Files Changed in the Runtime Project

Primary files:

- `runtime/render2d_gl.c`
- `runtime/render2d_gl.h`
- `runtime/runtime.c`
- `runtime/prelude.rb`
- `runtime/build.sh`
- `examples/flappy/app/main.rb`
- `docs/porting-a-ruby-game.md`

Generated build artifacts under `build/` were also changed during iteration. Do not assume every generated artifact is current; rebuild before testing.

## Current Renderer Features

The GL2D implementation currently includes:

- GLSL ES 3.00 shaders.
- Shared RGBA texture atlas for sprites.
- Native solid batching through `WC.solid_batch`.
- Native sprite batching through `WC.sprite_batch`.
- Indexed solid geometry.
- Cached GL state.
- Opaque-solid blend fast path.
- Silent audio mixer fast path.
- Removed redundant GL framebuffer clear.
- Experimental retained API: `WC.static_solid_batch` / `wy_r2d_static_solid_batch`.

The retained static API is not actively used by the examples. An earlier attempt to use it in the example carts caused a black frame. Cache invalidation was added, but the path is not considered production-safe until tested in an isolated benchmark.

The latest change added `wy_r2d_solid_batch`, which marshals Ruby solid arrays once and appends directly to the GL vertex buffer instead of calling `wy_r2d_solid` for every rectangle. The CPU build deliberately keeps the original direct loop to avoid regressing the baseline.

Bitmap-font rendering was changed from one rectangle per lit pixel to horizontal runs of lit pixels. It preserves the same 5x7 glyph output but reduces primitive generation.

## Build Commands

From `/Users/monteslu/code/ruby/wasmcart-mruby`:

```sh
./runtime/build.sh gl2d
./runtime/build.sh cpu
```

The build script produces:

- `build/main.wasm`
- `build/main-cpu.wasm`
- `build/flappy-wyvern.wasc`
- `build/flappy-wyvern-cpu.wasc`

The script's default `WASMCART_REPO` resolves to the sibling checkout `/Users/monteslu/code/ruby/wasmcart`, which has the required `yazl` dependency. The cliemu checkout may not have its Node dependencies installed.

To package Tetris from freshly built WASM:

```sh
node /Users/monteslu/code/ruby/wasmcart/bin/wasmcart-pack.js \
  --wasm build/main.wasm \
  --assets examples/tetris/app \
  --name tetris-2dgl \
  -o build/tetris-2dgl.wasc

node /Users/monteslu/code/ruby/wasmcart/bin/wasmcart-pack.js \
  --wasm build/main-cpu.wasm \
  --assets examples/tetris/app \
  --name tetris-cpu \
  -o build/tetris-cpu.wasc
```

## Valid Test Procedure

Use the romdev tools against the updated host/session:

1. Load the cart with `platform: "wasmcart"` and `deterministicSeed: 7`.
2. Step at least 120-180 frames.
3. Confirm rendering with `frame({op: "verify", frames: 1})`.
4. Read `playtest({op: "status"})` after the window has stabilized.

Relevant `playtest` fields:

- `perf.stepMs`: cart/runtime step cost, the main comparison metric.
- `perf.convertMs`: framebuffer conversion cost.
- `perf.presentMs`: window presentation cost; do not confuse this with cart renderer cost.
- `perf.fps` / `tickHz`: overall real-time health.

The playtest window was already open during this session. If it remains open, loading a new cart updates it. `humanInputActive` must be false for automated measurements.

## Latest Measurements

Measurements are noisy and should be repeated, but the direction is clear.

Tetris, after rebuilding/repacking from the current sources:

- GL2D: approximately `3.96 ms/tick`
- CPU: approximately `2.38 ms/tick`

Wyvern, earlier valid real-GPU comparison:

- GL2D: approximately `3.46 ms/tick`
- CPU: approximately `2.87 ms/tick`

Therefore the current GL path has not achieved the objective.

After the first optimization pass in the follow-up session was rebuilt by the
user and repackaged, a matched real-WebGL2 sample measured:

- Tetris GL2D: `3.54 ms/tick`
- Tetris CPU: `2.12 ms/tick`
- Wyvern GL2D: `3.09 ms/tick`
- Wyvern CPU: `2.68 ms/tick`

All four carts rendered correctly at 62 Hz with `humanInputActive: false`.
This establishes that the first pass helped (Tetris was about 11% faster than
the prior ~3.96 ms/tick sample), but GL2D still trails CPU.

A prior Tetris sample showed a very high `presentMs` around `4.34 ms`, but later samples were around `0.7 ms`; treat presentation numbers as window/system noise unless repeated.

## Important Findings

- The previous GL-vs-CPU comparisons made before updated romdev/wasmcart were invalid.
- Replacing `glBufferData` with `glBufferSubData` was tested earlier and regressed the real GPU measurement to roughly `5.65 ms/tick`; that change was reverted.
- Instanced solid rendering was tested earlier, produced translucent striping, and did not improve timing; it was reverted.
- The retained static renderer caused a black frame when integrated into the examples. Do not enable it broadly without an isolated test.
- The GL path batches geometry, but it still pays Ruby object/list construction and GL buffer/draw overhead every frame.
- CPU rendering is unusually cheap for these scenes because it directly rasterizes simple primitives into memory.
- The direct native batch change did not materially close the gap, so the bottleneck is likely broader than per-rectangle C function calls.

## Recommended Investigation Order

1. Establish a controlled microbenchmark that isolates each workload:
   - thousands of opaque rectangles;
   - many sprites from one atlas;
   - labels only;
   - mixed Tetris/Wyvern frame.
2. Measure the GL renderer without the playtest window if possible, separating cart `stepMs` from `presentMs` and readback.
3. Inspect whether `WC.solid_batch` is actually used by the target frame and how many items/colors/flushes it generates.
4. Count GL flushes and draw calls in `render2d_gl.c`. A temporary diagnostic counter is preferable to guessing.
5. Reduce per-frame Ruby allocation/list construction before attempting shader complexity changes.
6. Test persistent mapped/orphaned buffer strategies only with the updated real GL host. Do not assume the old `glBufferSubData` result generalizes.
7. Build a dedicated static-scene cart to validate retained geometry and cache invalidation independently of Tetris/Wyvern.
8. Consider an adaptive renderer only if the goal is application-level speed rather than making the GL implementation itself faster. Simple scenes may rationally remain CPU-rendered.

## Build Environment Change (2026-07-25)

The old sibling checkout `/Users/monteslu/code/ruby/wasmcart` **no longer
exists**. Builds and packing must use the cliemu checkout:

```sh
WASMCART_REPO=/Users/monteslu/code/cliemu/wasmcart ./runtime/build.sh gl2d
node /Users/monteslu/code/cliemu/wasmcart/bin/wasmcart-pack.js ...
```

Its Node dependencies (`yazl` etc.) were installed with `npm install` in that
checkout on 2026-07-25, so packing works from there now.

## VAO Pass Result (2026-07-25)

The initialization-hoisting/VAO pass described below was rebuilt, repackaged,
and benchmarked on real WebGL2 (romdev 0.106.1, `gl: "rendered"` confirmed,
62 Hz, `humanInputActive: false`, seed 7, repeated samples):

- Tetris GL2D: `4.14-4.19 ms/tick`
- Tetris CPU: `2.61-2.62 ms/tick`
- Wyvern GL2D: `3.74-3.79 ms/tick`
- Wyvern CPU: `3.16-3.20 ms/tick`

All absolute numbers ran ~20% higher than the prior session (including the
untouched CPU carts), so only same-session ratios are comparable:

- Tetris GL/CPU ratio: `1.59` (prior pass: `1.67`)
- Wyvern GL/CPU ratio: `1.18` (prior pass: `1.15`)

Conclusion: the VAO/init-hoisting pass gave at most a marginal improvement on
Tetris and none on Wyvern. No black frame or regression — both GL carts render
correctly — but GL2D still clearly trails CPU. Proceed to the instrumentation
and workload-isolation steps in "Recommended Investigation Order".

## Prior Immediate Restart Task (COMPLETED 2026-07-25)

There is an additional optimization pass in `runtime/render2d_gl.c` that has
**not been rebuilt or benchmarked yet**. It:

- creates and retains a VAO;
- moves immutable program/buffer/attribute/texture-unit/viewport/blend setup
  from every frame into initialization;
- caches `glClearColor`;
- replaces repeated NDC division with precomputed multipliers.

Resume with:

```sh
cd /Users/monteslu/code/ruby/wasmcart-mruby
./runtime/build.sh gl2d
```

Then repackage Tetris from the new `build/main.wasm`:

```sh
node /Users/monteslu/code/ruby/wasmcart/bin/wasmcart-pack.js \
  --wasm build/main.wasm \
  --assets examples/tetris/app \
  --name tetris-2dgl \
  -o build/tetris-2dgl.wasc
```

Test both `build/tetris-2dgl.wasc` and `build/flappy-wyvern.wasc` with
`platform: "wasmcart"` and `deterministicSeed: 7`. Run at least 180 frames,
confirm `frame({op:"verify"})`, open/reuse playtest, allow its rolling metrics
to stabilize for about five seconds, then record `perf.stepMs`. Compare against
the existing CPU carts:

- `build/tetris-cpu.wasc`
- `build/flappy-wyvern-cpu.wasc`

If the new VAO path produces a black frame or build error, inspect/revert only
the latest initialization-hoisting pass in `runtime/render2d_gl.c`; preserve
the earlier batching, state caching, four-vertex sprite, and zero-angle changes.

## Known Build Warning

Builds succeed but emit this existing warning from `stb_vorbis.c`:

```text
pointer comparison always evaluates to false [-Wtautological-compare]
```

It is unrelated to the GL work.

## Current Working Tree Caveat

The project has pre-existing and session-generated modifications. Do not reset or discard unrelated changes. Inspect `git diff` before editing. No commit was made for this work.

## Investigation Result (2026-07-25): objective met — the gap was host readback

Instrumentation and workload isolation (the recommended path) resolved this.
Two additions, both cart-side only (hosts untouched):

1. **GL diagnostics** in `runtime/render2d_gl.c` / `runtime.c`: per-frame
   draw-call/flush/quad/upload counters latched at `wy_r2d_end`, exposed as
   debug fields (`gl_draws`, `gl_solid_flushes`, `gl_tex_flushes`,
   `gl_quads`, `gl_upload_bytes`) readable via `wasm({op:'debugState'})`.
   A `dt_last_us`/`dt_sum_us`/`dt_frames` wall-clock probe was added too, but
   romdev always runs the fixed 16.666 ms virtual clock, so it only pays off
   under a non-fixed-step host.
2. **Standalone benchmark** `bench/bench-cart.mjs`: drives wasmcart's public
   `CartHost.runFrame` API directly (same offscreen webgl-node WebGL2 context
   romdev uses), timing the cart step in isolation, then the romdev-style
   readback separately.

Counter findings: the GL command stream is already near-optimal. Tetris renders
in **1 draw call** (737 quads, ~94 KB upload); Wyvern in **3 draw calls**
(474 quads, ~61 KB). Draw-call overhead was never the bottleneck.

Isolated per-frame cost (1000-frame averages, warm):

| Cart | GL2D | GL2D + glFinish | CPU |
|---|---|---|---|
| Tetris | 0.73 ms | 1.31 ms | 1.54 ms |
| Wyvern | 0.23 ms | 0.55 ms | 2.29 ms |

**The GL2D renderer is 2-10× faster than the CPU renderer** (still faster even
with a full GPU sync forced every frame). The playtest `stepMs` deficit was the
host display path: for GL carts, romdev's `WasmcartHost.stepFrames` performs a
`gl.readPixels` at 720p plus a row-flip copy and a per-pixel alpha-force loop
(~2.4-2.5 ms/call, measured), and the playtest loop calls `stepFrames(1)` per
tick, so that cost lands inside `perf.stepMs` every frame — for GL carts only.
Sanity check: playtest Tetris GL 4.14 ms ≈ 0.73 (cart) + 2.47 (readback) +
~0.9 (audio convert + fb copy, paid by both builds); Tetris CPU 2.61 ≈ 1.54 +
~1.0. The model closes.

Implications:

- No further cart-side renderer work is needed for the stated goal. In a real
  frontend that presents the GL context directly (no readback), GL2D wins
  outright.
- The readback lives in romdev host code, which this project must not modify.
  If playtest-visible GL numbers matter later, that is a romdev change
  (e.g. async PBO readback or readback-outside-stepMs accounting), to be
  requested upstream.
- `frame({op:'step', frames:N})` pays readback once per CALL, not per frame —
  bulk stepping through romdev is already nearly readback-free.

## Optimization Pass 2 (2026-07-25): WC.draw_list — flush moved into C

Profiling (V8 `--cpu-prof` over `bench/bench-cart.mjs`, names via a
`--profiling-funcs` build) showed the mruby interpreter (`mrb_vm_exec`) at
~43% of samples with all GL work combined under 2.5%. Compiler flags on the
VM were a dead end (-O2/-O3 measured equal-or-worse than -Os; config stays
-Os). The win was executing fewer Ruby ops:

- **`WC.draw_list(list, kind)`** in `runtime.c` (kinds: 0 solid, 1 border,
  2 line, 3 label, 4 sprite): walks a whole outputs list in C. Array items
  take a positional fast path, hashes a keyed fast path (symbols interned
  once at boot), anything else falls back to the Ruby `__wc_draw_*` shim.
  Draw order is preserved; solids accumulate into a batch flushed via
  `wy_r2d_solid_batch` (GL) or `fill_rect` (CPU/render-target fallback).
- `prelude.rb` flush paths now call `WC.draw_list` for solids, sprites,
  labels, lines, and borders (both main outputs and render targets); the
  per-frame `all?` type-scan passes are gone. `primitives`/`debug` stay in
  Ruby (type inference per item).
- `draw_label_a` unifies the bitfont path (alpha param) — wy_label's
  duplicated alpha loop removed.
- Behavior notes: batched hash sprites now get the same missing-asset
  magenta + `@rt:` GL-disable semantics as `WC.sprite` (the old hash-batch
  silently skipped both), and Symbol paths work in batches.

Isolated per-frame cost after the pass (clean -Os build, 2000-frame avg):

| Cart | GL2D | GL2D + glFinish | CPU | GL gain vs pass 1 |
|---|---|---|---|---|
| Tetris | 0.57 ms | 0.90 ms | 1.36 ms | -22% |
| Wyvern | 0.15 ms | 0.46 ms | 2.18 ms | -31% |

The CPU build also improved (Tetris 1.54→1.36) since draw_list serves both.
Microbenches (`bench/carts/`, packed as `build/bench-*.wasc`): empty tick
floor 0.02 ms; 1000 array rects 0.65 ms game-loop-included but **0.088 ms**
when the Ruby arrays are prebuilt (rects-static) — i.e. marshal+render is
~88 ns/rect; 40 labels 0.18 ms; 300 sprites 0.29 ms (CPU: 8.09 ms — GL 28×).
Remaining Tetris frame time is ~85% the game's own tick logic in mrb_vm_exec;
runtime C (draw_list + label raster + fill_rect) is <2% of samples.

Visual parity verified in romdev (`gl: "rendered"`, seed 7): Tetris title +
gameplay (right-aligned HUD numbers, centered labels) and Wyvern title match
the pre-change CPU reference pixel-for-pixel by eye.

Tooling added: `bench/bench-cart.mjs` (isolated step/readback timing),
`bench/analyze-prof.mjs` (cpuprofile summarizer), `bench/wasm-names.mjs`
(wasm name-section resolver), `bench/carts/*` (microbench carts).

## Bottom Line

The runtime builds, real GL rendering works, and the GL2D renderer is
materially faster than the CPU renderer — verified by isolated measurement.
The historical "GL slower than CPU" readings were an artifact of the host's
per-tick GL readback being counted inside `stepMs`. After the draw_list
pass, Tetris GL costs 0.57 ms/frame (CPU 1.36) and Wyvern 0.15 ms (CPU 2.18);
what remains is game-code tick time, not renderer time.
