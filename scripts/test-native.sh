#!/bin/zsh
# Compiles the helper's core sources with the native unit tests and runs them.
set -euo pipefail
ROOT=${0:A:h:h}
OUT="$ROOT/build/native-tests"
mkdir -p "$OUT"
SRC=("$ROOT"/native/SafariAgent/Core/*.swift "$ROOT"/native/SafariAgent/Providers/*.swift)
xcrun swiftc -swift-version 5 -O -o "$OUT/NativeTests" "${SRC[@]}" "$ROOT/native/Tests/main.swift" -framework SafariServices 2>&1 | grep -E "error" || true
"$OUT/NativeTests"
