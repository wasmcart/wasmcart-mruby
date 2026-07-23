# Porting an existing Ruby game to a `.wasc` cart

You have a Ruby game - most likely written for DragonRuby GTK - and you want
it running as a wasmcart cartridge: on a handheld (Batocera, Knulli,
ROCKNIX), on your TV through RetroArch on SteamOS / Bazzite, in a browser,
or in a terminal. This is the map.

## First: wasmcart games are gamepad games

wasmcart is a *cartridge console* contract, and the devices you're targeting
 -  handhelds, TV boxes, RetroArch - are controller-first. **Design your
controls for a gamepad**: d-pad + A/B/X/Y + shoulders + start/select, plus
analog sticks. There is no mouse, and "keyboard" in this runtime is an alias
for the pad (arrow keys and space map onto d-pad and A in the players, so
desktop testing still feels natural). If your game leans on typing or mouse
aiming, redesign that interaction first - everything else below is
mechanical.

## Coverage at a glance

Rule of thumb: the code a typical 2D arcade game is *made of* is ~95%
covered; DragonRuby's full documented surface is roughly half, and most of
the remainder is desktop/OS glue a sandboxed cartridge deliberately
excludes.

**Ports directly (✓):**

- the `tick args` loop, 60fps, bottom-left 1280x720
- `args.outputs.solids / sprites / borders / lines / labels / primitives /
  debug / static_* / background_color` and **render targets**
  (`args.outputs[:name]`, drawn via `path: :name`)
- sprites: PNG, spritesheet `source_x/y/w/h`, flips, `angle`, r/g/b/a tint
- `primitives` z-ordering with inferred or explicit `primitive_marker`;
  `attr_sprite` / `attr_rect` / `attr_label` / `attr_line` object shoveling
- `args.inputs.controller_one`: all buttons, `key_down` edges, analog sticks
- `args.state` (`||=` init, `new_entity`), `args.tick_count` /
  `Kernel#tick_count` / `args.state.tick_count`
- `args.geometry`: `intersect_rect?`, `inside_rect?`, `point_inside_rect?`,
  `distance`, `angle_to`/`angle_from`, `center`, `scale_rect`
- `args.easing.ease` (identity/flip/quad/cube/quart/quint/smooth variants)
- sounds as WAVs incl. `args.audio` channels with gain and looping
- multi-file games via `require`, `puts` debugging, `rand` (deterministic
  under seeded replay)

**Partial (works, differently):**

| DragonRuby | Here |
|---|---|
| TTF fonts | Yes: `font: 'fonts/foo.ttf'` on labels (anti-aliased, kerned, alpha). `size_px` is the scale knob (8px of glyph height per unit, matching the bitfont); no `size_enum`, `alignment_enum` 0/1/2 only |
| deep `args.state.player.x` auto-nesting | initialize first: `args.state.player ||= args.state.new_entity(:player)` |
| `args.grid.origin_center!` | fixed bottom-left origin |
| engine hot-reload while running | dev-mode directory: edit Ruby, reload the cart (a second or two) |

**Also covered now:** `controller_one` through `controller_four` (+
`args.inputs.controllers`), `Numeric#frame_index` / `elapsed_time`,
`args.gtk.calcstringbox` (TTF-aware), `line_intersect?` /
`find_intersect_rect` / `find_all_intersect_rect`, `cubic_bezier` / `bezier`
/ `ray_test` / `rotate_point`, full `Regexp` (onigmo), `JSON.parse` /
`#to_json`, **OGG audio assets**, and `args.audio` channel `pitch:`,
`paused:`, and `playtime:` (read = position, write = seek).

**Not implemented:** `args.outputs.screenshots` (a harness screenshots from
outside the cart), `size_enum` font sizing, `origin_center!`.

**Never (by design, not laziness):** mouse/touch and full keyboard (gamepad
console), and the `$gtk` desktop glue: `read_file`/`write_file` (SRAM
instead), `http_get` (networking is wasmcart's own opt-in ABI), `openurl`,
`system`, C extensions. A cart is pure compute over the ABI; that's what
makes it safe and portable.

## What needs adapting

| In your game | Here |
|---|---|
| `require 'app/foo.rb'` | Works - files load from cart assets (no Regexp class in the build, plain paths only) |
| TTF fonts, `size_enum` | Built-in 5x7 bitfont; use `size_px` (pixel scale) and `alignment_enum` 0/1/2 |
| Mouse / full keyboard | Gamepad only - see above |
| `args.audio[:music] = {...}` | Works: gain, looping, pitch, paused, playtime seek, delete-to-stop; WAV + OGG |
| `$gtk.write_file` / reading files | Cart SRAM: `args.gtk.save_u32 slot, v` / `load_u32 slot` (64 slots, persisted by hosts as `<cart>.sav`, savestate-safe in RetroArch) |
| Render targets, easing, `args.outputs.static_*` | Not implemented - restructure or draw per tick |
| `Regexp`, `File`, `Dir`, threads | Not in the sandbox - carts are pure compute over the ABI |

Ruby dialect: this is mruby 3.4 - modern Ruby, but skip endless method
definitions (`def x = y`) and bare `module_function`; use classic `def` and
`def self.x`.

## Build the cart

```bash
git clone https://github.com/wasmcart/wasmcart-mruby
cp -r wasmcart-mruby/template my-game
cd my-game
rm app/main.rb && cp -r /path/to/your/game/app/* app/   # your Ruby + assets
./run.sh                                                # window opens; iterate
```

Iterate by editing Ruby and rerunning - the directory IS a dev-mode cart, no
build step. When it plays right:

```bash
npx wasmcart pack --wasm main.wasm --assets app --name my-game -o my-game.wasc
```

`my-game.wasc` is the single shippable file. Same artifact everywhere; no
per-platform builds.

## Run it on your devices

- **RetroArch anywhere (SteamOS, Bazzite, desktop):** install the
  [wasmcart-libretro](https://github.com/wasmcart/wasmcart-libretro) core
  (`wasmcart_libretro.so` + its `.info` into RetroArch's `cores/` directory  - 
  on Steam Deck that's the flatpak path
  `~/.var/app/org.libretro.RetroArch/config/retroarch/cores`). Then Load
  Content → `my-game.wasc`. Gamepad, audio, save states, shaders, netplay
  come from RetroArch.
- **Handhelds (Batocera, Knulli, ROCKNIX):** these ship RetroArch under the
  hood - install the core the same way and drop `.wasc` files in your roms
  tree.
- **Desktop, quickly:** `npx wasmcart my-game.wasc` (SDL window, gamepad,
  audio) - or `--term` over SSH.
- **Browser:** the `wasmcart` npm package's `CartHostWeb` runs the same file
  with WebGL2 and gamepad support.

## Debugging while you port

Every cart made with this runtime is observable by tooling: named debug
state (`args.gtk.debug_score = v`), frame-stamped `puts` and
`args.gtk.debug_mark id` events, and deterministic seeded replay for
regression goldens. A Ruby exception never crashes the cart - you get the
message on-screen and in the host log with a frame number. If you use an
MCP-capable harness (e.g. `romdevtools`), it can drive and screenshot your
port headlessly while you fix the diffs.
