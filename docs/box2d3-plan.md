# Box2D 3 wasmcart Integration Plan

## Goal

Build a second, self-contained wasm engine with Box2D 3 compiled directly into
the module. Keep the existing lightweight runtime unchanged for carts that do
not need physics.

Target artifacts:

```text
build/main.wasm
build/main-box2d3.wasm
```

The cart manifest selects the engine through `entry`:

```json
{
  "entry": "main-box2d3.wasm"
}
```

The Box2D build must not depend on native `.dylib`, `.so`, Ruby FFI, or
`dlopen`. Box2D, the bridge, and mruby all ship inside the wasm module.

Rendering is a separate concern. For the hardware path, the physics transform
batch feeds the scene renderer described in `docs/hardware-3d-plan.md`; Box2D
must remain usable with the existing CPU framebuffer renderer.

## 1. Pin Box2D

Add Box2D as a pinned source dependency under:

```text
runtime/vendor/box2d/
```

Record the exact upstream commit and version. The Box2D source and any new
bridge code must retain their applicable licenses.

Use Box2D's C API directly. Box2D 3 exposes stable opaque IDs such as
`b2WorldId`, `b2BodyId`, `b2ShapeId`, and `b2JointId`, which are a good fit for
a Ruby-to-C boundary.

## 2. Define The Ruby API

Expose a high-level API inspired by existing Ruby Box2D bindings without
copying a native FFI API:

```ruby
world = args.physics.world(
  gravity_x: 0,
  gravity_y: -9.8,
  pixels_per_meter: 32
)

body = world.create_body(:dynamic, x: 300, y: 500)
body.add_box(w: 32, h: 32, density: 1.0)
body.apply_force(x: 100, y: 0)

world.step
body.position
```

Initial API surface:

- `Physics::World`
- `Physics::Body`
- `Physics::Shape`
- `Physics::Joint`
- box, circle, capsule, polygon, and chain shapes
- body transforms and velocities
- forces and impulses
- collision filters
- sensors
- contact events
- raycasts and overlap queries
- debug drawing
- world profiling and counters

Keep physics state native. Ruby objects should hold compact handles rather than
mirroring the full Box2D object graph.

## 3. Coordinate And Timing Rules

Box2D uses meters and Cartesian coordinates. The existing runtime uses pixels,
a bottom-left origin, and a 1280x720 canvas.

The wrapper should:

- expose pixels to Ruby by default
- convert to meters internally
- support configurable `pixels_per_meter`
- preserve the existing bottom-left coordinate convention
- expose angles in degrees
- use a fixed simulation timestep

Default stepping should be deterministic:

```ruby
world.step fixed_delta: 1.0 / 60.0
```

Do not derive physics time directly from wall-clock time. The host can render
at a variable rate while the physics simulation advances in fixed increments.

## 4. Runtime Bridge

Add a focused bridge instead of placing all physics code in `runtime/runtime.c`:

```text
runtime/physics_box2d3.c
runtime/physics_box2d3.h
```

The bridge owns:

- world, body, shape, and joint handle tables
- native allocation and destruction
- Ruby method registration
- coordinate conversion
- contact and sensor event collection
- batched body snapshots
- task scheduling
- profiling data

Register a small low-level module such as `WC::Physics`. The Ruby prelude
should wrap it with the public `args.physics` API.

## 5. Build A Box2D Variant

Extend `runtime/build.sh` with a separate target:

```bash
./runtime/build.sh
./runtime/build.sh box2d3
```

The Box2D target should:

- compile Box2D
- compile the physics bridge
- link mruby
- enable wasm SIMD
- optionally enable pthread support
- emit `build/main-box2d3.wasm`
- report size and enabled capabilities

The normal build must continue to emit `build/main.wasm` without Box2D.

Compile Box2D with stronger optimization than the general mruby runtime where
profiling supports it:

```text
-O3
-msimd128
```

Keep the existing runtime flags stable initially.

## 6. SIMD

Use wasm SIMD for the Box2D build:

```text
-msimd128
```

Expose the capability to Ruby and the harness:

```ruby
args.physics.capabilities.simd
```

If compatibility testing finds hosts that cannot load SIMD modules, produce a
scalar fallback:

```text
build/main-box2d3-simd.wasm
build/main-box2d3-scalar.wasm
```

SIMD should be the default Box2D artifact when the supported wasmcart hosts can
load it.

## 7. Threaded Task Scheduling

Box2D 3 does not create threads itself. It exposes `enqueueTask`,
`finishTask`, and `workerCount`; the embedding application supplies the task
system.

Implement a runtime task system with:

- a fixed worker pool
- Box2D enqueue and finish callbacks
- worker index tracking
- bounded task allocation
- serial execution for small tasks
- safe shutdown during cart reload

Do not set `workerCount > 1` unless the host supports:

- shared wasm memory
- wasm atomics
- pthread workers
- synchronization during tick and render calls

Expose capabilities:

```ruby
args.physics.capabilities.threads
```

Threaded execution should be capability-driven. The same Ruby game should run
serially when the host cannot provide workers.

Emscripten pthread builds will likely require flags equivalent to:

```text
-pthread
-sSHARED_MEMORY=1
-sPTHREAD_POOL_SIZE=...
```

Browser hosts also need `SharedArrayBuffer` and cross-origin isolation. Native,
terminal, and RetroArch hosts need their own compatibility checks.

## 8. Reduce Ruby Boundary Cost

Avoid fetching every body property individually in large simulations:

```ruby
bodies.each { |body| body.position }
```

Provide a batch path:

```ruby
world.sync_bodies
world.body_transforms
```

Return compact records containing:

- body handle
- x and y
- angle
- velocity
- awake state
- contact flags

This is likely more important than threading for small and medium scenes.

## 9. Fixed-Time Simulation And Determinism

Use a fixed timestep and explicit substep count when calling `b2World_Step`.

Seeded runs must produce repeatable body transforms and event sequences in the
serial build. Threaded builds should be tested for acceptable determinism and
document any floating-point ordering differences.

Ruby callbacks from worker threads must be prohibited. Worker callbacks may
only touch Box2D's task context and thread-safe immutable data.

## 10. Debug And Profiling

Expose Box2D profile and counter data through named debug fields:

- awake body count
- body count
- shape count
- contact count
- physics step time
- collision time
- solver time
- task count
- worker count
- SIMD enabled
- threaded execution enabled

Expose `b2World_GetProfile` and `b2World_GetCounters` to the wasmcart harness.

This makes serial, SIMD, and threaded builds measurable rather than relying on
visual impressions.

## 11. Physics Demo Cart

Add a reference cart:

```text
examples/physics/
  manifest.json
  run.sh
  app/main.rb
```

The demo should include:

- falling boxes
- stacked bodies
- chain terrain
- joints
- sensor contacts
- raycasts
- controller interaction
- debug visualization
- an in-game performance HUD

It should run with:

```bash
npx wasmcart examples/physics
```

## 12. Tests

Add deterministic tests for:

- world creation and destruction
- body creation and destruction
- gravity
- collision response
- sleeping
- sensors
- raycasts
- joints
- coordinate conversion
- fixed timestep reproducibility
- cart reload cleanup
- invalid handle safety
- Ruby exception safety

Run the same seeded scene against:

- serial scalar
- serial SIMD
- threaded SIMD

Compare transforms, contact events, and scores. Any intentional threaded
floating-point differences must be bounded and documented.

## 13. Performance Benchmarks

Create fixed benchmark scenes containing:

- 100 boxes
- 500 boxes
- 1,000 boxes
- stacked bodies
- many independent islands
- joint-heavy scenes
- collision-heavy scenes

Measure:

- total frame time
- physics step time
- Ruby bridge time
- render time
- memory use
- serial versus threaded speedup
- SIMD versus scalar speedup

Only enable threading by default if representative scenes benefit from it.
Box2D task overhead can exceed the benefit for small worlds.

## 14. Packaging And Compatibility

Document:

- supported SIMD hosts
- supported threaded hosts
- browser requirements for pthread builds
- scalar fallback behavior
- engine artifact selection
- Box2D version and license

The user-facing workflow should remain simple:

```json
{
  "entry": "main-box2d3.wasm"
}
```

## Recommended Order

1. Pin Box2D source and implement a serial bridge.
2. Add the `args.physics` Ruby API.
3. Build the falling-box demo.
4. Add deterministic tests.
5. Enable SIMD and benchmark it.
6. Add batched body synchronization.
7. Implement the threaded task pool.
8. Add host capability negotiation.
9. Benchmark threaded execution and choose the default policy.
10. Finish packaging and documentation.

The key policy is to make SIMD the normal Box2D build, while making threading
conditional on actual wasmcart host capabilities and measured benefit.
