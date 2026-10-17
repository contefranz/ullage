#!/bin/bash
# Claude Code cloud sessions: install the Swift 6.0 toolchain OrbitCore needs
# (Linux has none), put it on PATH for the session, and build the package and
# its tests once so the first `swift test` is incremental.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

SWIFT_DIR=/opt/swift
cd "$CLAUDE_PROJECT_DIR"

# Idempotent: the script returns at once when the toolchain is there.
bash scripts/install-swift-linux.sh "$SWIFT_DIR"

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=$SWIFT_DIR/usr/bin:\$PATH" >> "$CLAUDE_ENV_FILE"
fi
export PATH="$SWIFT_DIR/usr/bin:$PATH"

# Warm the build cache. A failure here must not block the session: the
# agent will see the same errors when it builds.
swift build --build-tests || echo "session-start: swift build --build-tests failed; see above" >&2
