#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sdk="${SDKROOT:-$(xcrun --sdk macosx26.5 --show-sdk-path 2>/dev/null || xcrun --sdk macosx --show-sdk-path)}"
mkdir -p .build build
stage="$(mktemp -d "$PWD/.build/package.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$PWD/build/查词.app"
cpus=("$(uname -m)")
flags=(-O)
case "${1:-}" in
  --dmg)
    mkdir "$stage/disk"
    app="$stage/disk/查词.app"
    cpus=(arm64 x86_64)
    flags+=(-D PORTABLE)
    ;;
  "") ;;
  *) echo "Usage: bash build.sh [--dmg]" >&2; exit 2 ;;
esac
resources="$app/Contents/Resources"
helper="$app/Contents/Helpers/阅读生词本.app"
runtime="$resources/runtime"
/usr/bin/python3 scripts/prepare_data.py
mkdir -p "$app/Contents/MacOS" "$helper/Contents/MacOS" "$runtime/book" "$runtime/data" "$resources/licenses"
if [[ "${1:-}" == --dmg ]]; then
  /usr/bin/python3 scripts/portable_runtime.py "$resources"
else
  /usr/bin/python3 -m pip install --disable-pip-version-check --no-compile --upgrade --target "$runtime/vendor" -r requirements.txt
fi
cp Info.plist "$app/Contents/Info.plist"
cp book/Info.plist "$helper/Contents/Info.plist"
cp runtime/backend.py runtime/example_service.py runtime/phrase_lookup.py "$runtime/"
cp runtime/book/*.py "$runtime/book/"
cp .build/data/{dictionary,examples}.sqlite "$runtime/data/"
cp LICENSE licenses/*.txt "$resources/licenses/"
build_executable() {
  local name="$1" output="$2" cpu
  shift 2
  local slices=()
  for cpu in "${cpus[@]}"; do
    xcrun swiftc -sdk "$sdk" -target "$cpu-apple-macosx26.0" "${flags[@]}" -module-name "$name" "$@" PythonRuntime.swift -o "$stage/$name-$cpu"
    slices+=("$stage/$name-$cpu")
  done
  xcrun lipo -create "${slices[@]}" -output "$output"
}
build_executable ReadingBook "$helper/Contents/MacOS/ReadingBook" book/*.swift
codesign --force --sign - "$helper"
build_executable OptionD "$app/Contents/MacOS/OptionD" Lookup.swift
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ "${1:-}" == --dmg ]]; then
  ln -s /Applications "$stage/disk/Applications"
  hdiutil create -quiet -volname "查词" -format UDZO -srcfolder "$stage/disk" "$stage/查词.dmg"
  mv -f "$stage/查词.dmg" build/查词.dmg
  echo "$PWD/build/查词.dmg"
else
  echo "$app"
fi
