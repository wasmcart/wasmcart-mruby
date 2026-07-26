# Hardware 3D Rendering Plan

## Where this stands (updated 2026-07-25)

The 2D GPU milestone is **complete and default**: `./runtime/build.sh` emits
the GL2D `main.wasm` (WebGL2 batched renderer, `runtime/render2d_gl.c`),
which is 2-14× faster than the CPU rasterizer with pixel-identical output
(commits `c294ad2`, `e81873e`; details and benchmarks in `HANDOFF.md`).
`./runtime/build.sh cpu` remains as a benchmarking comparator. GL is a host
requirement — every wasmcart/romdev host provides a WebGL2/GLES3 context —
so no design work targets GL-less hosts. CPU-only features (render targets,
TTF) auto-fall back to CPU rasterization + `wc_gl_blit` presentation.

What remains is the 3D renderer itself. The foundation is already in place:

- `wc_info_t.gpu_api` identifies WebGL2/GLES3 as API `1`.
- `runtime/wasmcart.h` declares the GLES3 import surface: shaders, programs,
  buffers, textures, uniforms, VAOs, instancing, framebuffers, depth/stencil.
- `render2d_gl.c` proves the batching, state-caching, and atlas patterns.

## The governing lesson from the 2D work

Profiling showed the mruby interpreter (`mrb_vm_exec`) dominating frame time
while all GL calls combined were under 2.5%. The 2D renderer got its 22-31%
win by moving per-item work out of Ruby into `WC.draw_list` (marshal whole
lists in one C call). 3D multiplies per-item cost by per-VERTEX cost, so the
rule is absolute:

> **Ruby describes the scene. C owns every per-vertex and per-instance loop.**

This is also why DragonRuby has no real 3D games: its triangle API makes
interpreted Ruby the vertex pipeline, which caps out at hobby-demo triangle
counts. The design below is the thing DragonRuby structurally cannot ship.

## Ruby API surface

**Not a three.js-style retained scene graph.** A mutable object graph
(`object.position.x += 1`, `scene.add(mesh)`) reintroduces exactly the
per-frame Ruby↔C chatter the 2D work eliminated (dirty tracking, Vec3
allocations, GC pressure), and retained mutable state breaks the cart ethos:
DragonRuby games rebuild outputs from `args.state` every tick, which is what
makes wasmcart's deterministic replay and frame-hash regression testing work.

Borrow three.js's *vocabulary* (camera, mesh, lights, materials), keep
DragonRuby's *object model*: immediate-mode data lists — "sprites, but with
a z axis." **Assets are retained; instances are immediate.**

```ruby
def tick(args)
  args.outputs.camera3d = { x: 0, y: 3, z: 8,
                            look_x: 0, look_y: 0, look_z: -5,
                            fov: 60, near: 0.1, far: 1000 }

  args.outputs.lights << { type: :ambient, r: 40, g: 40, b: 60 }
  args.outputs.lights << { type: :directional, x: -1, y: -2, z: -1,
                           r: 255, g: 244, b: 220 }

  args.outputs.models << {
    path: 'models/ship.obj',          # loaded + VBO-uploaded once, like sprite PNGs
    x: 0, y: 0, z: -5,
    rx: 0, ry: args.state.tick_count % 360, rz: 0,   # degrees, DragonRuby-style
    sx: 1, sy: 1, sz: 1,
    r: 255, g: 255, b: 255, a: 255,   # tint + alpha, same fields as sprites
  }
end
```

Design points:

- **`path` is the handle.** Same pattern as `sprite_get`: first use loads the
  OBJ (+MTL/PNG textures) from cart assets and uploads GPU buffers; later
  frames reference the cache. No handle-management API for carts.
- **Per-instance marshal is ~12 numbers.** Through a `WC.draw_list`-style
  whole-list C walker (array fast path, interned-symbol hash path), instance
  submission costs ~100 ns each — thousands of instances well under 0.1 ms.
  C composes the mat4 per instance and draws grouped by mesh+texture with
  instanced rendering.
- **Procedural geometry is build-once**: `WC.mesh(:terrain, vertices:, uvs:,
  normals:, indices:)` registers a named mesh; reference it with
  `path: :terrain`. Covers what DragonRuby users do with raw triangles,
  without per-frame vertex traffic.
- **Escape hatches, not a graph**: optional `transform: [16 floats]` for full
  matrix control. A `parent:` field can come later if hierarchy demand is
  real. No bones/animation until someone needs them.
- **Materials are fields, not objects**: unlit when no lights are declared,
  lambert when they are; `a: < 255` routes to an alpha pass sorted
  back-to-front in C; fog later as `args.outputs.fog = {...}`.
- **2D composites over 3D for free**: the 3D pass renders first (depth
  buffer on), then the existing GL2D pass draws on top — HUDs, labels, and
  menus work unchanged. This alone is a large DX win over DragonRuby
  raycaster-era games.
- **Determinism preserved**: everything is plain hashes/arrays rebuilt per
  tick; no GPU state is visible to Ruby, so seeded replays and frame-hash
  goldens keep working. (`compare-render.mjs` extends naturally to 3D
  GL-vs-reference checks.)

## Implementation order

Steps 1-5 of the original plan (host GL backend, smoke cart, `render2d_gl.c`,
GPU labels/lines/borders, deterministic backend comparison) are **done** via
the 2D milestone. Remaining:

1. **M1 — unlit meshes**: `runtime/render3d_gl.c` with camera3d + `models`
   list (OBJ loader, depth test, back-face culling, textured/vertex-color
   unlit shader). Cube + OBJ demo cart. Benchmark with `bench/bench-cart.mjs`;
   pixel-regression with a seeded golden.
2. **M2 — lights**: ambient/directional (lambert), tint/alpha pass with
   back-to-front sorting. Point lights only if a cart needs them.
3. **M3 — procedural meshes**: `WC.mesh` registration + `:symbol` paths;
   port a DragonRuby triangle demo as the compatibility proof.
4. **M4 — scale passes**: instanced draws grouped by mesh, frustum culling
   in C, optional retained static chunks (the `static_solid_batch` lesson:
   only with an isolated test cart first).
5. **Box2D/Box3D bridge**: the physics transform batch from
   `docs/box2d3-plan.md` feeds the same instance stream — physics stays
   renderer-independent.

## Relationship to DragonRuby

What real DragonRuby "3D" content uses today: textured **triangles** with
Ruby-side matrix math (the official `99_genre_3d` samples, Amir Rajan's OBJ
gist), **raycasters**, and pixel-array/software tricks. Full compatibility
with that ecosystem needs only the triangle primitive + mat4 helpers — worth
having via `WC.mesh`/M3 — but it is a demo-tier ceiling, not a design target.
The opportunity is the vacuum: Ruby developers have no path to shipping real
3D anywhere. This runtime, with C-side vertex work and a guaranteed GL host,
is that path.

## Host requirements (unchanged)

Browser WebGL2 and native GLES3 backends share the import names; the browser
path must copy out of wasm memory rather than assuming pointer access. Do not
advertise `gpu_api = 1` until context creation, shader compilation, and
present all work — already true for the hosts in use (romdev ≥ 0.106.1,
wasmcart ≥ 0.6.0, `wasmcart-play` windowed).
