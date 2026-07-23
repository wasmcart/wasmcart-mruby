#!/bin/bash
# Build the wyvern runtime -> ../build/wyvern.wasm
# Needs: emcc, host ruby+rake (first mruby build only), a wasmcart checkout
# for include/wc_cart.h + wc_pcm_mixer.h (WASMCART_REPO, default sibling).
set -e
cd "$(dirname "$0")"
WASMCART_REPO="${WASMCART_REPO:-../../wasmcart}"
MRUBY_TAG=3.4.0

if [ ! -f vendor/mruby/build/emscripten/lib/libmruby.a ]; then
  mkdir -p vendor
  [ -d vendor/mruby ] || git clone --depth 1 --branch "$MRUBY_TAG" https://github.com/mruby/mruby.git vendor/mruby
  (cd vendor/mruby && rake MRUBY_CONFIG=../../mruby_wasm_config.rb)
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

# -sSUPPORT_LONGJMP=wasm is REQUIRED (mruby exceptions are setjmp/longjmp;
# the default JS-trampoline form infinite-loops under import-stubbing hosts)
emcc runtime.c vendor/mruby/build/emscripten/lib/libmruby.a \
  -O2 -I vendor/mruby/include -I "$WASMCART_REPO/include" -I . \
  -s STANDALONE_WASM=1 --no-entry -sSUPPORT_LONGJMP=wasm \
  -s EXPORTED_FUNCTIONS='["_wc_init","_wc_render","_wc_get_info","_wc_debug_state","_wc_set_seed"]' \
  -s ERROR_ON_UNDEFINED_SYMBOLS=0 \
  -s ALLOW_MEMORY_GROWTH=1 -s INITIAL_MEMORY=67108864 -s STACK_SIZE=4194304 \
  -o ../build/wyvern.wasm
echo "built ../build/wyvern.wasm ($(wc -c < ../build/wyvern.wasm) bytes)"
