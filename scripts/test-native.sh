#!/bin/zsh
# Compiles the app's sources (without its main.swift) together with the native
# unit tests and runs them.
set -euo pipefail
ROOT=${0:A:h:h}
OUT="$ROOT/build/native-tests"
mkdir -p "$OUT"
SRC=("$ROOT"/native/SafariAgent/Core/*.swift "$ROOT"/native/SafariAgent/Providers/*.swift "$ROOT"/native/SafariAgent/Picker/*.swift
     "$ROOT"/native/SafariAgent/App/AppDelegate.swift "$ROOT"/native/SafariAgent/App/SettingsView.swift)
xcrun swiftc -swift-version 5 -O -o "$OUT/NativeTests" "${SRC[@]}" "$ROOT/native/Tests/main.swift" -framework SafariServices 2>&1 | grep -E "error" || true
"$OUT/NativeTests"
