#!/bin/bash
# copy the prebuilt engine in (once), then play this directory as a dev cart
set -e
cd "$(dirname "$0")"
[ -f cart.wasm ] || cp ../build/wyvern.wasm cart.wasm
npx wasmcart .
