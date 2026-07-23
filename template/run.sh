#!/bin/bash
# copy the prebuilt engine in (once), then play this directory as a dev cart
set -e
cd "$(dirname "$0")"
[ -f main.wasm ] || cp ../build/main.wasm main.wasm
npx wasmcart .
