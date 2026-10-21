#!/bin/bash
# Claude Code cloud sessions: install the Swift 6.0 toolchain OrbitCore needs
# (Linux has none), put it on PATH for the session, and build the package and
# its tests once in both test configurations, so that the first
# `scripts/test.sh` (fast) or `scripts/test.sh full` is incremental.
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

# Warm the build caches, the fast gate's first: hooks are cancelled after
# 600 s, and a cut-short build resumes where it stopped. A failure here must
# not block the session: the agent will see the same errors when it builds.
bash scripts/test.sh warm || echo "session-start: scripts/test.sh warm failed; see above" >&2
