#!/usr/bin/env bash
#
# mayhem/build.sh — build the mm0-c MM0 proof verifier harness(es).
#
# mm0-c is a single-translation-unit C program: main.c #includes parser.c -> verifier.c -> ...
# There is no library to link; the "harness" IS the program (a file-input target, argv[1] = .mmb).
# The original fork target compiled: `clang main.c -o mm0-c -D NO_PARSER` and fuzzed `/mm0-c @@`.
# We preserve that exactly (basename `mm0-c`), but build it instrumented with $SANITIZER_FLAGS +
# $DEBUG_FLAGS so the fuzzed verifier code (not just an entry stub) is checked for memory/UB defects.
#
# -D NO_PARSER: mm0-c then verifies only the .mmb (argv[1]) for internal correctness and ignores
#   stdin — this is the single-file-input mode Mayhem fuzzes (`/mayhem/mm0-c @@`).
#
# Runs inside the commit image as `mayhem` in /mayhem. The base exports CC/CXX/SANITIZER_FLAGS/
# DEBUG_FLAGS/SRC. Air-gapped: uses only clang + the in-tree sources (no network fetch).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Output binaries go under /mayhem/bin (NOT /mayhem/mm0-c — that path is the SOURCE directory
# mm0-c/, which the Dockerfile COPYs in; writing a binary there would collide with the dir).
mkdir -p /mayhem/bin

# ── 1) The fuzz target — mm0-c built instrumented (ASan+UBSan+DWARF<4) with -D NO_PARSER.
#      main.c pulls in the whole verifier via #include, so one compile builds everything.
#      Warnings are noisy (upstream style) but harmless; keep the build going.
#
# mm0-c never frees (verify-then-exit), so per-process LeakSanitizer-at-exit is pure overhead
# across thousands of fuzz iterations. Bake detect_leaks=0 as a linked default (NOT via the
# Mayhemfile's ASAN_OPTIONS env — Mayhem requires its own full baseline there, e.g.
# abort_on_error=1/symbolize=0/…, and a custom override that omits any of them breaks the
# fuzz driver). __asan_default_options() only adds to Mayhem's env, it doesn't replace it.
cat > /tmp/asan_opts.c <<'EOF'
extern const char *__asan_default_options(void) { return "detect_leaks=0"; }
EOF
"$CC" $DEBUG_FLAGS -c /tmp/asan_opts.c -o /tmp/asan_opts.o

echo ">> building fuzz target /mayhem/bin/mm0-c (instrumented, -D NO_PARSER)"
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -D NO_PARSER \
    "$SRC/mm0-c/main.c" /tmp/asan_opts.o -o /mayhem/bin/mm0-c
test -x /mayhem/bin/mm0-c

# ── 2) Standalone (non-fuzzer) reproducer. mm0-c already IS a run-once file-input program
#      (argv[1] = .mmb, runs once, crashes naturally), so it doubles as its own standalone
#      reproducer — no libFuzzer runtime is involved. Provide the conventional -standalone name
#      as a copy so triage tooling that expects `<target>-standalone` finds it.
echo ">> providing /mayhem/bin/mm0-c-standalone (mm0-c is already a run-once file-input driver)"
cp /mayhem/bin/mm0-c /mayhem/bin/mm0-c-standalone

# ── 3) The test/oracle binary — a SEPARATE clean build with the project's NORMAL flags and the
#      FULL checker (NO -D NO_PARSER), matching how upstream CI verifies proofs:
#          mm0-c foo.mmb < foo.mm0
#      test.sh runs this against known-good and corrupted .mmb fixtures (see mayhem/test.sh).
#      $COVERAGE_FLAGS is empty by default (no effect); set via --build-arg for coverage runs.
echo ">> building test oracle /mayhem/bin/mm0-c-test (clean, full checker)"
"$CC" -O2 $COVERAGE_FLAGS "$SRC/mm0-c/main.c" -o /mayhem/bin/mm0-c-test
test -x /mayhem/bin/mm0-c-test

echo ">> build.sh done:"; ls -1 /mayhem/bin/mm0-c /mayhem/bin/mm0-c-standalone /mayhem/bin/mm0-c-test
