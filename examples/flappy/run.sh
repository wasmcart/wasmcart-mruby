#!/bin/bash
set -e
cd "$(dirname "$0")"
[ -f cart.wasm ] || cp ../../build/wyvern.wasm cart.wasm
npx wasmcart .
