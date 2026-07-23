# wasmcart-mruby

**Write games in Ruby. Ship them as wasmcart carts.**

An experimental, for-the-fun-of-it mruby game runtime with APIs in the style
of DragonRuby GTK: `def tick args`, `args.outputs`, `args.inputs`,
`args.state`. It compiles to a single reusable `wyvern.wasm`; you write only
Ruby, the engine is prebuilt and ready. The same `.wasc` runs on every
wasmcart host: Node, browser, RetroArch, native players, handhelds, and
terminals. And the whole thing is free, MIT, all layers open.

wasmcart games are **gamepad games**: design for d-pad + face buttons +
sticks and they'll feel right on every device (desktop testing maps
arrows/space onto the pad for you).

```ruby
def tick args
  args.state.x ||= 600
  args.state.x += 5 if args.inputs.keyboard.right
  args.outputs.solids << [args.state.x, 300, 80, 80, 90, 220, 130]
  args.outputs.labels << { x: 640, y: 600, text: 'hello from ruby!',
                           size_px: 6, alignment_enum: 1 }
end
```

## Quick start

```bash
git clone https://github.com/wasmcart/wasmcart-mruby
cp -r wasmcart-mruby/template my-game
cd my-game && ./run.sh          # opens a window; edit app/main.rb, rerun
```

That's the whole loop: edit Ruby, run. No compiler, no toolchain - `run.sh`
copies the prebuilt engine (`build/wyvern.wasm`) next to your `manifest.json`
and plays the directory as a dev-mode cart via `npx wasmcart`. When you want
a shippable single file:

```bash
npx wasmcart pack --wasm cart.wasm --assets app --name my-game -o my-game.wasc
```

## The API (DragonRuby-style)

> If you want a mature, batteries-included commercial Ruby game engine,
> go buy [DragonRuby GTK](https://dragonruby.org/) - it's excellent, and its
> API idioms are the reason this project speaks the same dialect. This is an
> unaffiliated, experimental runtime that contains none of DragonRuby's code
> and doesn't claim compatibility; it exists because Ruby-games-as-open-
> cartridges is a fun idea. Both are built on [mruby](https://mruby.org/).

Everything happens in `tick args`, 60 times a second, on a 1280x720
bottom-left-origin canvas.

**Outputs** (shovel, redrawn every tick):

| Collection | Forms |
|---|---|
| `args.outputs.solids` | `[x, y, w, h, r, g, b, a]` or `{x:, y:, w:, h:, r:, g:, b:, a:}` |
| `args.outputs.sprites` | `{x:, y:, w:, h:, path: 'sprites/foo.png', source_x/y/w/h:, flip_horizontally:, flip_vertically:, angle:, r:, g:, b:, a:}` - PNG, spritesheet tiles, rotation, tint |
| `args.outputs.labels` | `{x:, y:, text:, size_px:, alignment_enum:, r:, g:, b:}` - built-in font, upper + lower case |
| `args.outputs.lines` / `borders` | `[x, y, x2, y2, r, g, b, a]` / rect forms |
| `args.outputs.primitives` / `debug` | ANY primitive type, drawn in shovel order (the z-ordering tool; `debug` renders topmost). Types inferred or set via `primitive_marker` |
| `args.outputs.static_*` | persist across ticks (shovel once) for every collection |
| `args.outputs[:name]` | **render target**: shovel into it, then draw it as a sprite with `path: :name` (rotate/scale/tint it like any sprite) |
| `args.outputs.sounds` | `'sounds/jump.wav'` (16 mixer voices), `{path:, gain:, looping:}`, or `{freq:, frames:}` beeps |
| `args.audio[:music] = { input:, gain:, looping: }` | persistent audio channels; mutate `gain`, `delete` to stop |
| `args.outputs.background_color` | `[r, g, b]` |

Primitives can also be **objects**: `class Foo; attr_sprite; end` (or
`attr_rect` / `attr_label` / `attr_line`) and shovel instances directly, the
DragonRuby OO idiom.

**Inputs** (gamepad-first - wasmcart is a cartridge console, controllers are
the primary input):

- `args.inputs.keyboard` / `args.inputs.controller_one` - held state:
  `.left .right .up .down .a .b .x .y .l1 .r1 .start .select`
- `.key_down.a` etc. - pressed-this-tick edges
- `.left_analog_x_perc` / `.left_analog_y_perc` - analog sticks, -1..1

**State and helpers:**

- `args.state.anything = value` - open-struct persistence between ticks
  (`args.state.score ||= 0`); `args.state.new_entity(:player, x: 0)`
- `args.geometry`: `intersect_rect?`, `inside_rect?`, `point_inside_rect?`,
  `distance`, `angle_to`/`angle_from`, `center`, `scale_rect` (arrays, hashes,
  or attr_rect objects)
- `args.easing.ease start, now, duration, :quad, :flip, ...` for animation
- `Numeric#to_radians` / `to_degrees` / `sign`
- `args.tick_count` (also `Kernel#tick_count` and `args.state.tick_count`), `args.grid`
- `puts` - captured by the host's debug event trace
- `args.gtk.save_u32 slot, v` / `load_u32 slot` - **cart SRAM** (64 slots,
  persisted as `<cart>.sav` by the player; how the flappy example keeps its
  hiscore)
- `args.gtk.debug_mark id` and harness debug slots - see Observability below

## Porting an existing Ruby game

Already have a game written in these idioms? See
**[docs/porting-a-ruby-game.md](docs/porting-a-ruby-game.md)** - what ports
directly, what to adapt (gamepad-first controls above all), and how to get
the `.wasc` onto handhelds and TVs via
[wasmcart-libretro](https://github.com/wasmcart/wasmcart-libretro)
(Batocera, Knulli, SteamOS/Bazzite through RetroArch).

## Example: FLAPPY WYVERN

`examples/flappy/` - a complete game (sprite animation with rotation, WAV
sound effects, parallax clouds, gradient-shaded pipes, SRAM hiscore) in ~180
lines of Ruby. `./run.sh` in that directory plays it. Its art and sounds are
generated by `tools/make-assets.mjs` - no binary assets you can't rebuild.

## Observability (why build on wasmcart)

Carts made with this runtime are **drivable and inspectable by tooling**, not
just playable by humans:

- named debug state readable by harnesses (`tick_count`, `score`, `aux`,
  `ruby_ok`; mirror your own via `args.gtk.debug_score = v`)
- frame-stamped event marks + captured `puts`
- **deterministic replay**: on seeded runs the host seed reaches `srand`, so
  `rand`-driven games reproduce bit-identical frame sequences - recorded
  goldens become airtight regression tests
- Ruby exceptions never crash the cart: they're logged, marked, and shown
  on-screen

Development harnesses (e.g. the `romdevtools` MCP server) can run, watch,
listen to, drive, and regression-test these carts headlessly.

## Rebuilding the engine (optional)

Game authors never need this. If you hack `runtime/runtime.c` or the Ruby
surface in `runtime/prelude.rb` (embedded into the wasm at build time):

```bash
WASMCART_REPO=/path/to/wasmcart runtime/build.sh
```

Needs emcc, host ruby+rake (mruby cross-build, cached after the first run),
and a wasmcart checkout for the SDK headers. Notable: `-sSUPPORT_LONGJMP=wasm`
is mandatory - mruby's exception handling breaks bizarrely without it.

## License

MIT, every layer: engine C, Ruby surface, cart format, hosts. mruby (MIT)
is fetched at engine-build time; stb_image (public domain / MIT) is
vendored. DragonRuby is a trademark of its owners; this unaffiliated project
contains none of its code. The repo is named for what it embeds (mruby,
Matz's embeddable Ruby, the same VM DragonRuby builds on); the API *style*
it follows is DragonRuby's.
