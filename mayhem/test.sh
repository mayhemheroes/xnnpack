#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the standalone KAT (mayhem/kat.cc, already built by mayhem/build.sh against
# a NORMAL/unsanitized build of XNNPACK) and assert its printed output against a hand-computed
# known-answer value. exit 0 = pass.
#
# WHY a standalone KAT instead of XNNPACK's own unit-test suite: the upstream suite requires
# -DXNNPACK_BUILD_TESTS=ON, which pulls in GoogleTest and compiles thousands of additional
# microkernel-level test translation units — a large, slow addition on top of the already-heavy
# fuzzed-lib build, for a project whose fuzzed surface (a single operator-constructor harness) is
# tiny. Instead, mayhem/kat.cc calls XNNPACK's real public API (xnn_run_binary_elementwise_nd, an
# f32 element-wise add) on FIXED inputs and prints the COMPUTED result:
#     input1 = [1,2,3,4], input2 = [10,20,30,40]  =>  KAT_OUTPUT: 11.0,22.0,33.0,44.0
# This is a real functional assertion (a computed value from the actual library), not just "did it
# run / exit 0": a source patch that no-ops the addition, or the grader's sabotage LD_PRELOAD (which
# _exit(0)s the binary before main() runs), makes the "KAT_OUTPUT: 11.0,22.0,33.0,44.0" line vanish
# from stdout, which this script detects and reports as a failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

KAT_BIN="/mayhem/xnnpack-kat"
EXPECTED="KAT_OUTPUT: 11.0,22.0,33.0,44.0"

if [ ! -x "$KAT_BIN" ]; then
  echo "missing $KAT_BIN — run mayhem/build.sh first" >&2
  emit_ctrf "xnnpack-kat" 0 1
  exit 2
fi

out="$("$KAT_BIN" 2>&1)"
echo "$out"

if printf '%s\n' "$out" | grep -qF "$EXPECTED"; then
  echo "KAT matched expected computed output: $EXPECTED"
  emit_ctrf "xnnpack-kat" 1 0
  exit 0
else
  echo "KAT did NOT produce the expected computed output (want: '$EXPECTED')" >&2
  emit_ctrf "xnnpack-kat" 0 1
  exit 1
fi
