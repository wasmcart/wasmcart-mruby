#!/bin/bash
set -e
cd "$(dirname "$0")"
[ -f main.wasm ] || cp ../../build/main.wasm main.wasm
npx wasmcart .
