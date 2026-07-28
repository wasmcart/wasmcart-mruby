#!/bin/bash
# Build the wyvern runtime -> ../build/wyvern.wasm
# Needs: emcc, host ruby+rake (first mruby build only), a wasmcart checkout
# for include/wc_cart.h + wc_pcm_mixer.h (WASMCART_REPO, default sibling).
set -e
cd "$(dirname "$0")"
WASMCART_REPO="${WASMCART_REPO:-../../wasmcart}"
MRUBY_TAG=3.4.0
TARGET="${1:-gl2d}"
DEFINES=""
OUTPUT="../build/main.wasm"
if [ "$TARGET" = "gl2d" ]; then
  DEFINES="-DWC_ENABLE_GL2D"
  OUTPUT="../build/main.wasm"
elif [ "$TARGET" = "cpu" ]; then
  OUTPUT="../build/main-cpu.wasm"
elif [ "$TARGET" != "cpu" ]; then
  echo "usage: $0 [cpu|gl2d]" >&2
  exit 2
fi

# embed the Ruby surface into the wasm (games ship only their own Ruby)
python3 - <<'PY'
data = open('prelude.rb', 'rb').read()
with open('prelude.inc', 'w') as f:
    f.write('static const unsigned char WY_PRELUDE[] = {')
    f.write(','.join(str(b) for b in data))
    f.write('};\n')
    f.write(f'static const unsigned int WY_PRELUDE_LEN = {len(data)};\n')
PY

if [ ! -f vendor/mruby/build/emscripten/lib/libmruby.a ]; then
  mkdir -p vendor
  [ -d vendor/mruby ] || git clone --depth 1 --branch "$MRUBY_TAG" https://github.com/mruby/mruby.git vendor/mruby
  ONIGMO_GEM="vendor/mruby/build/repos/emscripten/mruby-onig-regexp/mrbgem.rake"
  if [ -f "$ONIGMO_GEM" ]; then
    ruby - "$ONIGMO_GEM" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
old = 'make -j#{$rake_jobs || 1} libonigmo.la onigmo.pc'
flags = "CFLAGS='-Os -g0 -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables'"
old_with_flags = "CFLAGS='-Os -g0' #{old}"
unless source.include?('fno-asynchronous-unwind-tables') || source.include?(old) || source.include?(old_with_flags)
  abort "unexpected mruby-onig-regexp build command"
end
unless source.include?('fno-asynchronous-unwind-tables')
  source = source.sub(old_with_flags, "#{flags} #{old}")
  source = source.sub(old, "#{flags} #{old}")
end
source = source.sub("e['CFLAGS'] = '-Os -g0'", "e['CFLAGS'] = '-Os -g0 -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables'")
if source.include?('`ar x #{oniguruma_lib}`')
  source = source.sub(/      FileUtils\.mkdir_p libonig_objs_dir.*?      # onigmo wasm objects are linked by wasmcart's build\.sh/m,
                       "      # Link the source-built Onigmo objects directly;\n      # macOS ar corrupts wasm members during archive extraction.")
  source = source.sub(/    if File\.exist\? oniguruma_lib.*?    end\n\n    cc\.include_paths/m,
                       "    cc.include_paths")
end
File.write(path, source)
RUBY
  fi
  (CFG="$(pwd)/mruby_wasm_config.rb"; cd vendor/mruby && rake MRUBY_CONFIG="$CFG")
fi

# mruby-onig-regexp's archive extraction is unreliable with wasm objects on
# macOS, so the gem patch above stops it extracting and we link the
# source-built Onigmo objects directly instead. They remain fully inside the
# cart either way.
#
# On Linux `ar x` works, so the gem's own extraction succeeds and those
# objects are ALREADY inside libmruby.a -- adding them again is a duplicate
# symbol for every one of them (~20 link errors, and the build never
# completes). Only pass them when the archive does not already carry them.
ONIGMO_OBJS=()
if ! "${EMAR:-emar}" t vendor/mruby/build/emscripten/lib/libmruby.a 2>/dev/null \
     | grep -q '^regcomp\.o$'; then
  for obj in vendor/mruby/build/emscripten/mrbgems/mruby-onig-regexp/onigmo-6.2.0/*.o \
             vendor/mruby/build/emscripten/mrbgems/mruby-onig-regexp/onigmo-6.2.0/enc/*.o; do
    [ -f "$obj" ] && ONIGMO_OBJS+=("$obj")
  done
fi

# -sSUPPORT_LONGJMP=wasm is REQUIRED (mruby exceptions are setjmp/longjmp;
# the default JS-trampoline form infinite-loops under import-stubbing hosts)
emcc runtime.c render2d_gl.c vendor/mruby/build/emscripten/lib/libmruby.a "${ONIGMO_OBJS[@]}" \
  -O2 -I vendor/mruby/include -I "$WASMCART_REPO/include" -I . \
  $DEFINES \
  -s STANDALONE_WASM=1 --no-entry -sSUPPORT_LONGJMP=wasm \
  -s EXPORTED_FUNCTIONS='["_wc_init","_wc_render","_wc_get_info","_wc_debug_state","_wc_set_seed"]' \
  -s ERROR_ON_UNDEFINED_SYMBOLS=0 \
  -s ALLOW_MEMORY_GROWTH=1 -s INITIAL_MEMORY=67108864 -s STACK_SIZE=4194304 \
  -o "$OUTPUT"
echo "built $OUTPUT ($(wc -c < "$OUTPUT") bytes)"

# pack the flagship example as a ready-to-run demo cart
PACK_NAME="flappy-wyvern"
[ "$TARGET" = "cpu" ] && PACK_NAME="flappy-wyvern-cpu"
PACK_OUTPUT="../build/${PACK_NAME}.wasc"
node "$WASMCART_REPO/bin/wasmcart-pack.js" \
  --wasm "$OUTPUT" --assets ../examples/flappy/app \
  --name "$PACK_NAME" --width 1280 --height 720 \
  -o "$PACK_OUTPUT" > /dev/null
echo "packed $PACK_OUTPUT (npx wasmcart $PACK_OUTPUT to play)"
