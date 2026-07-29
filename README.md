# wasmcart-mruby

**Write games in Ruby. Ship them as wasmcart carts.**

An experimental, for-the-fun-of-it [mruby](https://mruby.org/) game runtime with
APIs in the style of DragonRuby GTK: `def tick args`, `args.outputs`,
`args.inputs`, `args.state`. It compiles to a single reusable engine wasm; you
write only Ruby, the engine is prebuilt and ready. The same `.wasc` runs on every
[wasmcart](https://github.com/wasmcart/wasmcart) host: Node, browser,
[RetroArch](https://www.retroarch.com), native players, handhelds, and
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

**Just want to play something?** Prebuilt carts are attached to the
[latest release](https://github.com/wasmcart/wasmcart-mruby/releases/latest) —
Flappy Wyvern, Neon Blocks, and the API showcase. Download one and run it:

```bash
npx wasmcart flappy-wyvern.wasc
```

To write your own:

```bash
git clone https://github.com/wasmcart/wasmcart-mruby
cp -r wasmcart-mruby/template my-game
cd my-game && ./run.sh          # opens a window; edit app/main.rb, rerun
```

That's the whole loop: edit Ruby, run. No compiler, no toolchain - `run.sh`
copies the prebuilt engine (`build/main.wasm`) next to your `manifest.json`
and plays the directory as a dev-mode cart via
[`npx wasmcart`](https://www.npmjs.com/package/wasmcart). When you want
a shippable single file:

```bash
npx wasmcart pack --wasm cart.wasm --assets app --name my-game \
  --width 1280 --height 720 -o my-game.wasc
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
| `args.audio[:music] = { input:, gain:, looping:, pitch:, paused:, playtime: }` | persistent channels: live gain/pitch/pause, playtime seek; WAV and OGG |
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
- output too: `args.gtk.rumble` drives the pad's motors (see State and helpers)

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
- `args.gtk.rumble low, high, ms` / `rumble_stop` / `rumble?` - **gamepad
  rumble**. `low` is the low-frequency "strong" motor, `high` the
  high-frequency "weak" one, both `0.0..1.0`; `ms` is capped at 5000 by the
  host. A 4th argument picks the controller, 0-based like
  `args.inputs.controllers[i]`. Rumble is a per-DEVICE capability, so
  `rumble?` asks; calls on a pad without motors are silent no-ops, and the
  host's own timer stops them, so sustained rumble means re-arming each tick
- `args.gtk.debug_mark id` and harness debug slots - see Observability below

## Networking (`args.net`)

wasmcart has one networking primitive: a **connection to a peer**. Open one,
send bytes, receive bytes, learn when it opens or closes. What the connection
actually is underneath (a WebSocket, a WebRTC data channel, a LAN socket, a
serial cable) is the host's business, and a cart cannot tell. That is what
makes a networked cart portable.

DragonRuby has no equivalent, so this part of the surface is the engine's own.
It lives in its own `args.net` object rather than as `args.gtk.net_*` because
it is stateful the way `args.outputs` and `args.audio` are, not a one-shot host
call the way `rumble` is. `args.gtk` keeps thin `net_open` / `net_send` /
`net_broadcast` / `net_close` / `net_state` / `net_peers` / `net_name` aliases
for code that only has `gtk` in hand.

```ruby
def tick args
  args.state.peer ||= args.net.open('wss://example.com/lobby')   # id, or nil
  args.net.send   args.state.peer, "\x01#{args.state.x.to_i}"
  args.net.broadcast 'ping'                                       # every open peer
end

# All four callbacks are optional; define the ones you want at top level,
# next to tick. They fire at the TOP of the tick after the event arrived.
def net_connected args, peer, name; args.state.players[peer] = { name: name }; end
def net_message   args, peer, data; end
def net_disconnected args, peer;    args.state.players.delete peer; end
def net_error     args, peer;       end
```

| Call | Returns |
|---|---|
| `args.net.open address` | peer id, or `nil` if the host refused |
| `args.net.send peer, data` | bytes accepted, or `nil` |
| `args.net.broadcast data` | how many peers took it, or `nil` |
| `args.net.close peer` | `nil` |
| `args.net.state peer` | `:connecting` / `:open` / `:closing` / `:closed` |
| `args.net.open? peer` | boolean |
| `args.net.peers` / `count` | every peer id the host holds |
| `args.net.name peer` | display String, or `nil` |
| `args.net.transport peer` | `[:reliable, :ordered, :low_latency]` subset, possibly empty |
| `args.net.overflow` | `[events_dropped, payloads_truncated]` since boot |

Things worth knowing before you build on it:

- **Both gates are required to dial out.** The engine always sets
  `WC_FLAG_NET_PEER` (one wasm serves every wyvern cart, so it cannot know at
  build time whether your Ruby wants networking), but the *manifest* must also
  grant the address. Pack with `--ws <domain>` for each domain you dial, or
  write `"net": { "domains": [...] }` in your own manifest. Without a grant,
  `args.net.open` returns `nil` every time. Peers the **host** registers reach
  the cart regardless: that is the host's own decision, not reach the cart
  asked for.
- **Messages are binary only.** Payloads are Ruby Strings of raw bytes,
  embedded NULs and all. Text framing is your job (`JSON.generate`, a length
  prefix, whatever). Nothing on the path treats a payload as text or as UTF-8.
- **`peer` is the handle, `name` is decoration.** The id is a small integer,
  stable for the session, and the only thing to key a player table on. The
  name comes from a remote machine, so it is **attacker-controlled text**: the
  engine bounds it to 64 bytes, but it is not unique, not stable across
  sessions, not necessarily valid UTF-8, and must never be used as a hash key
  or trusted for anything that matters. Draw it and nothing else.
- **Addressing is the host's grammar, not the spec's.** `wss://host/room` on a
  host that speaks WebSocket; a room code or a device path on one that does
  not. A host that does not understand an address simply fails the open, so
  handle `nil`.
- **Events are queued, not reentrant.** The host delivers them outside a
  frame; the engine buffers them and drains the queue at the top of the next
  tick, in arrival order, so a networked game stays replayable under the
  deterministic clock. The queue holds 64 events of up to 4096 bytes each
  between two ticks; a peer that floods past that has its **oldest** events
  dropped and its oversized payloads clamped, both counted in
  `args.net.overflow`.
- **Networking is not deterministic.** Replay and the seeded RNG cover cart
  logic, not what arrives from the network.

Verify the whole path against a real socket with
`node bench/verify-net.mjs` (see Observability).

## How much of DragonRuby's API?

The core a 2D arcade game actually touches is ~95% covered: every output
collection including render targets and primitives z-ordering, attr_sprite
objects, four controllers with analog, state, geometry (including the
intersection finders), easing, `frame_index` animation sugar, WAV audio
channels, SRAM persistence, multi-file `require`, plus full `Regexp`,
`JSON`, TTF fonts, OGG audio, and bezier/ray geometry. Measured against DragonRuby's entire documented surface it's roughly
half; most of the gap is desktop/OS glue (files, HTTP, windowing, mouse)
that a sandboxed gamepad cartridge deliberately excludes. The full matrix, including partial
implementations and the roadmap, lives in
[docs/porting-a-ruby-game.md](docs/porting-a-ruby-game.md).

## Porting an existing Ruby game

Already have a game written in these idioms? See
**[docs/porting-a-ruby-game.md](docs/porting-a-ruby-game.md)** - what ports
directly, what to adapt (gamepad-first controls above all), and how to get
the `.wasc` onto handhelds and TVs via
[wasmcart-libretro](https://github.com/wasmcart/wasmcart-libretro)
(Batocera, Knulli, SteamOS/Bazzite through RetroArch).

## Example: FLAPPY WYVERN

[`examples/flappy/`](examples/flappy) - a complete game (sprite animation with
rotation, WAV sound effects, parallax clouds, gradient-shaded pipes, SRAM
hiscore) in ~180 lines of Ruby. `./run.sh` in that directory plays it. Its art
and sounds are generated by
[`examples/flappy/tools/make-assets.mjs`](examples/flappy/tools/make-assets.mjs) -
no binary assets you can't rebuild.

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

Development harnesses (e.g. the [`romdevtools`](https://www.npmjs.com/package/romdevtools)
MCP server) can run, watch,
listen to, drive, and regression-test these carts headlessly.

The repo's own end-to-end checks drive the engine through wasmcart's public
`CartHost` API, no host code modified:

```sh
node bench/verify-rumble.mjs     # gamepad rumble, with a no-rumble control pass
node bench/verify-net.mjs        # peer networking against a live WebSocket server
```

`verify-net.mjs` starts wasmcart's `test/wsserver.mjs` and runs three real
cases through it: an `/echo` round trip with a payload containing embedded NULs
and a `0xFF` byte, two separate carts talking through `/relay/<room>`, and a
`/drop` endpoint that closes on the cart so the disconnect path is real. Its
last section is a control: the same cart wasm packed with **no** manifest net
grant, which must score differently or the test is measuring nothing.

## Rebuilding the engine (optional)

Game authors never need this. If you hack `runtime/runtime.c` or the Ruby
surface in `runtime/prelude.rb` (embedded into the wasm at build time):

```bash
WASMCART_REPO=/path/to/wasmcart runtime/build.sh
```

Needs [emcc](https://emscripten.org), host ruby+rake (mruby cross-build, cached
after the first run), and a [wasmcart](https://github.com/wasmcart/wasmcart)
checkout for the SDK headers ([`include/`](https://github.com/wasmcart/wasmcart/tree/main/include)). Notable: `-sSUPPORT_LONGJMP=wasm`
is mandatory - mruby's exception handling breaks bizarrely without it.

## The wasmcart org

This is one language runtime among several. Every repo below produces or runs
the *same* `.wasc` carts, so a host that plays one plays them all. Full list:
**[github.com/orgs/wasmcart/repositories](https://github.com/orgs/wasmcart/repositories)**

| Repo | What it is |
|------|------------|
| [**wasmcart**](https://github.com/wasmcart/wasmcart) | the spec, the JS reference hosts (`CartHost`, `CartHostWeb`), and the `wasmcart` CLI + packer |
| [**wasmcart-mruby**](https://github.com/wasmcart/wasmcart-mruby) (this repo) | write games in Ruby (mruby runtime, DragonRuby-style API) |
| [**wasmcart-lua**](https://github.com/wasmcart/wasmcart-lua) | write games in Lua (Lua 5.4, LÖVE-style API, batched GL2D renderer) |
| [**wasmcart-pygame**](https://github.com/wasmcart/wasmcart-pygame) | write games in Python (CPython 3.13 + pygame-ce) |
| [**wasmcart-jsgame**](https://github.com/wasmcart/wasmcart-jsgame) | write games in JavaScript (QuickJS, Canvas 2D + WebGL2 + Web Audio) |
| [**wasmcart-sdl2**](https://github.com/wasmcart/wasmcart-sdl2) | SDL2 backend + porting guide, for bringing existing C/SDL games over |
| [**wasmcart-libretro**](https://github.com/wasmcart/wasmcart-libretro) | libretro core - run carts in RetroArch / RetroDECK |
| [**wasmcart-native**](https://github.com/wasmcart/wasmcart-native) | native player built on libnode, no Node install needed |

## License

MIT, every layer: engine C, Ruby surface, cart format, hosts. [mruby](https://github.com/mruby/mruby)
(MIT) is fetched at engine-build time; [stb_image](https://github.com/nothings/stb)
(public domain / MIT) is vendored. DragonRuby is a trademark of its owners; this unaffiliated project
contains none of its code. The repo is named for what it embeds (mruby,
Matz's embeddable Ruby, the same VM DragonRuby builds on); the API *style*
it follows is DragonRuby's.
