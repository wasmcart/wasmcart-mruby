# Changelog

## 0.3.0

**The host frame clock reaches Ruby.** `tick` runs once per host frame, so a game that moves a fixed amount per tick
runs fast on a display above 60 Hz. The runtime already read the host's `wc_time` but never handed it to Ruby.
`args.gtk.delta_ms` and `args.gtk.time_ms` (and `WC.delta_ms` / `WC.time_ms` underneath) return Floats in milliseconds:
the time since the last frame, already clamped by the host, and the time since start. Under the deterministic clock
(`--seed`) `delta_ms` is a constant 16.667 and `time_ms` advances by exactly that per tick, so seeded replays stay
bit-identical.

**The vendored `wasmcart.h` matches wasmcart 0.41.1.** It had fallen behind the spec: no `WC_GLYPH_*` button glyph
constants, no asset prefetch constants, no `hardware_threads` in `wc_host_info_t`. It now carries all of them, and the
engine exports `wc_alloc` / `wc_free` from the header. The example and template manifests say `"abi": 4`, which the
engine has targeted since 0.2.0.

**Checks.** `bench/verify-clock.mjs` checks the clock against the deterministic and the real host clock, each the
other's control (the engine from 0.2.1 fails all seven checks). `bench/verify-all.mjs` runs the header drift check
and the clock, rumble and networking checks against both engine builds; it is the release gate.

**Docs.** The README and the porting guide say `tick` runs once per host frame and show how to step by `delta_ms`.
The porting guide's adapting table had stale rows claiming no `Regexp`, no TTF fonts and no render targets, easing
or `static_*`; all of those work and the rows are gone.

## 0.2.1

Carts carry their real version: the packed cart takes it from the git tag (wasmcart-pack 0.39.0 or later).

## 0.2.0

wasmcart ABI v4 (int16 triggers, u32 buttons), `args.net` peer networking, gamepad rumble, the vendored header drift
check, and the tetris example renamed to blocks.

## 0.1.0

First release: the mruby runtime with a DragonRuby-style API, the GL 2D renderer, and the flappy-wyvern, blocks and
showcase carts.
