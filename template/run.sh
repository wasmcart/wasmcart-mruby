#!/bin/bash
# copy the prebuilt engine in (once), then play this directory as a dev cart
set -e
cd "$(dirname "$0")"
if [ ! -f main.wasm ]; then
  # inside the repo (template/), or copied next to a wasmcart-mruby clone
  for engine in ../build/main.wasm ../wasmcart-mruby/build/main.wasm; do
    if [ -f "$engine" ]; then cp "$engine" main.wasm; break; fi
  done
fi
if [ ! -f main.wasm ]; then
  echo "no engine here: copy wasmcart-mruby/build/main.wasm next to manifest.json" >&2
  exit 1
fi
npx wasmcart .
