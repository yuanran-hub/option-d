#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Prefer the matching SDK on Command Line Tools installations that include multiple generations.
sdk="${SDKROOT:-$(xcrun --sdk macosx26.5 --show-sdk-path 2>/dev/null || xcrun --sdk macosx --show-sdk-path)}"
arch="$(uname -m)"
target="$arch-apple-macosx26.0"
app="$PWD/build/Option D.app"
helper="$app/Contents/Helpers/阅读生词本.app"
runtime="$app/Contents/Resources/runtime"
/usr/bin/python3 scripts/prepare_data.py
mkdir -p "$app/Contents/MacOS" "$helper/Contents/MacOS" "$runtime/book" "$runtime/data" "$app/Contents/Resources/licenses"
/usr/bin/python3 -m pip install --disable-pip-version-check --no-compile --upgrade --target "$runtime/vendor" -r requirements.txt
cp Info.plist "$app/Contents/Info.plist"
cp book/Info.plist "$helper/Contents/Info.plist"
cp runtime/backend.py runtime/example_service.py "$runtime/"
cp runtime/book/*.py "$runtime/book/"
cp .build/data/{dictionary,examples}.sqlite "$runtime/data/"
cp LICENSE licenses/*.txt "$app/Contents/Resources/licenses/"
xcrun swiftc -sdk "$sdk" -target "$target" -O -module-name ReadingBook book/*.swift -o "$helper/Contents/MacOS/ReadingBook"
codesign --force --sign - "$helper"
xcrun swiftc -sdk "$sdk" -target "$target" -O -module-name OptionD Lookup.swift -o "$app/Contents/MacOS/OptionD"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
