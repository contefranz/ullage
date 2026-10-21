#!/usr/bin/env bash
# Compiles every shader module the renderer builds at runtime (ShaderCommon,
# the module's headers, its source; `ShaderModule.all`) with the Metal
# compiler's warnings on, and fails on any error or warning. macOS only: it
# needs Xcode's Metal toolchain (xcrun metal). Arguments go to the compiler,
# e.g. scripts/check-shaders.sh -Wextra
set -euo pipefail
cd "$(dirname "$0")/.."

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
swift build -c release --product orbitsnap >/dev/null
"$(swift build -c release --show-bin-path)/orbitsnap" --dump-shaders "$dir"

status=0
for source in "$dir"/*.metal; do
  module=$(basename "$source" .metal)
  if out=$(xcrun -sdk macosx metal -Wall -Werror "$@" -c "$source" -o "$dir/$module.air" 2>&1); then
    echo "$module: clean"
  else
    echo "$module: FAILED"
    echo "$out" | sed "s|$dir/||"
    status=1
  fi
done
exit $status
