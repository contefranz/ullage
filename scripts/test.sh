#!/usr/bin/env bash
# The test gate, in two modes that run the same tests:
#   fast (default)  optimised build, tests in parallel worker processes; the
#                   gate at every merge. -enable-testing keeps @testable
#                   imports working in release.
#   full            Debug build, tests run serially (plain `swift test`); the
#                   gate at a milestone's close.
#   warm            build the tests in both configurations, fast first, and
#                   run nothing (the cloud SessionStart hook uses it).
# Arguments after the mode go to `swift test`, e.g.
#   scripts/test.sh fast --filter OrbitInstrumentsTests
#   scripts/test.sh fast --no-parallel    # optimised but serial, all output shown
# In parallel runs a test's output is shown only if it fails; run serially
# with --filter to read a printout such as AscentResidualTests' §17 residuals.
# A run ends with one line giving the number of tests it ran and failed and
# its times, so the two modes can be compared. Its output is kept in
# .build/test-<mode>.log.
set -euo pipefail
cd "$(dirname "$0")/.."

FAST=(-c release -Xswiftc -enable-testing)

mode=${1:-fast}
[ $# -gt 0 ] && shift
case "$mode" in
  fast) flags=("${FAST[@]}"); run=(--parallel --xunit-output .build/test-fast.xml) ;;
  full) flags=(); run=() ;;
  warm)
    swift build --build-tests "${FAST[@]}"
    swift build --build-tests
    exit 0 ;;
  *) echo "usage: scripts/test.sh [fast|full|warm] [swift test arguments...]" >&2; exit 2 ;;
esac

log=.build/test-$mode.log
start=$SECONDS
swift build --build-tests ${flags[@]+"${flags[@]}"}
built=$SECONDS
rm -f .build/test-fast.xml
status=0
swift test --skip-build ${flags[@]+"${flags[@]}"} ${run[@]+"${run[@]}"} "$@" 2>&1 | tee "$log" || status=$?
end=$SECONDS

# SwiftPM writes XCTest's xUnit report only for parallel runs; a serial run
# is counted from XCTest's own lines.
if [ -f .build/test-fast.xml ]; then
  tests=$(grep -c '<testcase ' .build/test-fast.xml || true)
  failed=$(grep -c '<failure' .build/test-fast.xml || true)
else
  tests=$(grep -c -E "^Test Case '.+' (passed|failed|skipped)" "$log" || true)
  failed=$(grep -c -E "^Test Case '.+' failed" "$log" || true)
fi
echo "test.sh $mode: $tests tests, $failed failed;" \
  "build $((built - start)) s, tests $((end - built)) s, total $((end - start)) s"
exit $status
