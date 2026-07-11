#!/usr/bin/env bash
#
# mayhem/build.sh — build google/XNNPACK's OSS-Fuzz harness (fuzz_model) + a standalone KAT.
#
# XNNPACK is a huge ML-kernel library (thousands of generated microkernel .c files across ISA
# variants); scoping "just what the fuzzer needs" isn't possible at the source level — the public
# API the harness calls (xnn_create_convolution2d_nhwc_qs8) is implemented inside the single
# `XNNPACK` static lib that CMake links from ALL enabled microkernels, so this builds that lib in
# full (same scope as upstream's own OSS-Fuzz build.sh: -DXNNPACK_BUILD_BENCHMARKS=OFF only). It
# does NOT build XNNPACK's own unit-test suite (XNNPACK_BUILD_TESTS) or benchmarks — those pull in
# GoogleTest/GoogleBenchmark and are unrelated to the fuzzed surface; the functional oracle here is
# a small standalone KAT (mayhem/kat.cc, see mayhem/test.sh) instead.
#
# Two CMake configs are built:
#   build-san/    — the fuzzed lib, WITH $SANITIZER_FLAGS + $DEBUG_FLAGS (ASan+UBSan, DWARF<4).
#                   Feeds the libFuzzer target + the *-standalone reproducer.
#   build-normal/ — a CLEAN, unsanitized build. Feeds mayhem/kat.cc (the test.sh oracle), kept
#                   independent of the sanitizer flags so the oracle can't be confounded by benign UB.
#
# Air-gap (SPEC §6.5): XNNPACK's CMakeLists.txt fetches three small deps at CONFIGURE time
# (cpuinfo, pthreadpool, and — transitively, from inside pthreadpool's own CMakeLists.txt — FXdiv)
# via CMake ExternalProject/git-clone, which needs network. We fetch each ONCE (network available
# at image-build time) into a persistent cache under $SRC/.xnnpack-deps-cache, then pass
# -D{CPUINFO,PTHREADPOOL,FXDIV}_SOURCE_DIR pointing at that cache on every subsequent configure —
# XNNPACK's own CMakeLists.txt guards its download step with `IF(NOT DEFINED <X>_SOURCE_DIR)`, so
# once the cache exists, no ExternalProject/network step is even invoked. Re-running this script
# under `--network none` (the idempotent air-gapped-rebuild gate) is a no-op fetch + a fast
# incremental cmake/make. The commit image is the ONLY consumer of these dep sources, so the cache
# lives under $SRC (not /opt) to stay writable by the mayhem user without extra Dockerfile chown.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

DEPS_ROOT="$SRC/.xnnpack-deps-cache"
mkdir -p "$DEPS_ROOT"

# ── 0) Prefetch cpuinfo/pthreadpool/FXdiv ONCE into $DEPS_ROOT (network; skipped if already cached) ──
if [ ! -d "$DEPS_ROOT/cpuinfo-source" ] || [ ! -d "$DEPS_ROOT/pthreadpool-source" ] || [ ! -d "$DEPS_ROOT/FXdiv-source" ]; then
  echo "=== prefetching XNNPACK's CMake deps (cpuinfo, pthreadpool, FXdiv) ==="
  PREFETCH_DIR="$(mktemp -d)"
  cmake -S "$SRC" -B "$PREFETCH_DIR" \
    -DXNNPACK_BUILD_BENCHMARKS=OFF -DXNNPACK_BUILD_TESTS=OFF \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" >/tmp/xnnpack-prefetch.log 2>&1 \
    || { echo "prefetch configure failed:" >&2; tail -100 /tmp/xnnpack-prefetch.log >&2; exit 1; }
  for d in cpuinfo-source pthreadpool-source FXdiv-source; do
    if [ -d "$PREFETCH_DIR/$d" ]; then
      rm -rf "${DEPS_ROOT:?}/$d"
      cp -r "$PREFETCH_DIR/$d" "$DEPS_ROOT/$d"
    else
      echo "expected dependency dir missing after prefetch: $d" >&2
      exit 1
    fi
  done
  rm -rf "$PREFETCH_DIR"
fi

CMAKE_DEP_ARGS=(
  -DCPUINFO_SOURCE_DIR="$DEPS_ROOT/cpuinfo-source"
  -DPTHREADPOOL_SOURCE_DIR="$DEPS_ROOT/pthreadpool-source"
  -DFXDIV_SOURCE_DIR="$DEPS_ROOT/FXdiv-source"
)
# The static-lib targets the fuzz harness / KAT link against (main lib + the two microkernel
# libs CMake splits PROD/ALL microkernels into) plus the two vendored deps.
XNN_TARGETS=(XNNPACK xnnpack-microkernels-all xnnpack-microkernels-prod pthreadpool cpuinfo)

# ── 1) Sanitized build (the fuzzed surface: XNNPACK itself, instrumented) ───────────────────────────
echo "=== configuring+building sanitized XNNPACK (ASan+UBSan, DWARF<4) ==="
cmake -S "$SRC" -B "$SRC/build-san" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DXNNPACK_BUILD_BENCHMARKS=OFF -DXNNPACK_BUILD_TESTS=OFF \
  "${CMAKE_DEP_ARGS[@]}" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake --build "$SRC/build-san" -j"$MAYHEM_JOBS" --target "${XNN_TARGETS[@]}"

SAN_LIBS=(
  "$SRC/build-san/libXNNPACK.a"
  "$SRC/build-san/libxnnpack-microkernels-all.a"
  "$SRC/build-san/libxnnpack-microkernels-prod.a"
  "$SRC/build-san/pthreadpool/libpthreadpool.a"
  "$SRC/build-san/cpuinfo/libcpuinfo.a"
)
INC_FLAGS=(-I"$SRC/include" -I"$DEPS_ROOT/pthreadpool-source/include")

# ── 2) fuzz_model: libFuzzer target + standalone (non-fuzzer) reproducer ───────────────────────────
echo "=== building fuzz_model (fuzzer + standalone) ==="
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
  "$SRC/mayhem/harnesses/fuzz_model.cc" "${INC_FLAGS[@]}" "${SAN_LIBS[@]}" \
  -o /mayhem/fuzz_model

# C++ harness: compile the run-once driver as C first so its LLVMFuzzerTestOneInput reference keeps
# C linkage (clang++ would otherwise mangle the ref and miss the harness's extern "C" definition).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
  "$SRC/mayhem/harnesses/fuzz_model.cc" /tmp/standalone_main.o "${INC_FLAGS[@]}" "${SAN_LIBS[@]}" \
  -o /mayhem/fuzz_model-standalone

# ── 3) Normal (unsanitized) build, for the KAT oracle only ──────────────────────────────────────────
echo "=== configuring+building normal (unsanitized) XNNPACK for the KAT oracle ==="
cmake -S "$SRC" -B "$SRC/build-normal" \
  -DCMAKE_BUILD_TYPE=Release \
  -DXNNPACK_BUILD_BENCHMARKS=OFF -DXNNPACK_BUILD_TESTS=OFF \
  "${CMAKE_DEP_ARGS[@]}" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
cmake --build "$SRC/build-normal" -j"$MAYHEM_JOBS" --target "${XNN_TARGETS[@]}"

NORMAL_LIBS=(
  "$SRC/build-normal/libXNNPACK.a"
  "$SRC/build-normal/libxnnpack-microkernels-all.a"
  "$SRC/build-normal/libxnnpack-microkernels-prod.a"
  "$SRC/build-normal/pthreadpool/libpthreadpool.a"
  "$SRC/build-normal/cpuinfo/libcpuinfo.a"
)
echo "=== building the KAT oracle binary (mayhem/kat.cc) ==="
$CXX -O2 "$SRC/mayhem/kat.cc" "${INC_FLAGS[@]}" "${NORMAL_LIBS[@]}" -o /mayhem/xnnpack-kat

echo "build.sh: done — /mayhem/fuzz_model, /mayhem/fuzz_model-standalone, /mayhem/xnnpack-kat"
