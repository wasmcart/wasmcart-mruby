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

## What ports directly

If your game lives in `tick args` and uses these, it ports with little or no
change:

- `args.outputs.solids / sprites / labels / lines / borders / sounds`
- `args.inputs.controller_one` (or `.keyboard` d-pad/A/B-style checks)
- `args.state` (including `||=` init and `new_entity`)
- `args.geometry.intersect_rect?` and friends, `args.tick_count`
- sprites as PNGs, including spritesheet `source_x/y/w/h`, flips, `angle`
- sound effects as WAVs, `rand`-driven logic, `puts` debugging

## What needs adapting

| In your game | Here |
|---|---|
| `require 'app/foo.rb'` | Works - files load from cart assets (no Regexp class in the build, plain paths only) |
| TTF fonts, `size_enum` | Built-in 5x7 bitfont; use `size_px` (pixel scale) and `alignment_enum` 0/1/2 |
| Mouse / full keyboard | Gamepad only - see above |
| `args.audio[:music] = {...}` | Works: persistent channels, gain, looping, delete-to-stop |
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
npx wasmcart pack --wasm cart.wasm --assets app --name my-game -o my-game.wasc
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
