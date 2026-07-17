#!/usr/bin/env bash
#
# mayhem/test.sh — functional oracle for the mm0-c MM0 proof verifier.
#
# Runs the CLEAN full-checker binary (/mayhem/mm0-c-test, built by mayhem/build.sh WITHOUT
# -D NO_PARSER) the way upstream CI does — `mm0-c PROOF.mmb < SPEC.mm0` — and ASSERTS behavior,
# not just exit status:
#   * KNOWN-GOOD proofs must VERIFY (exit 0): the minimal empty proof and the full Peano-arithmetic
#     proof (examples/peano.{mmb,mm0}, vendored under mayhem/tests/).
#   * A CORRUPTED / TRUNCATED .mmb must be REJECTED (non-zero exit) — a verifier that accepts
#     garbage is broken.
# The negative case is what makes this reward-hack-proof: a PATCH that neuters mm0-c to `exit(0)`
# passes the positives but FAILS the "must reject bad input" checks -> the sabotage oracle fails it.
#
# Emits a CTRF summary line for the grader. Do NOT compile here — build.sh produced the binary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

BIN=/mayhem/bin/mm0-c-test
T="$SRC/mayhem/tests"
if [ ! -x "$BIN" ]; then
  echo "ERROR: $BIN missing — mayhem/build.sh did not produce the test oracle" >&2
  emit_ctrf "mm0-c" 0 1 0
  exit 1
fi

passed=0; failed=0

# expect_verify <name> <mmb> <mm0-or-/dev/null>  : proof must be ACCEPTED (exit 0)
expect_verify() {
  local name="$1" mmb="$2" mm0="$3"
  if "$BIN" "$mmb" < "$mm0" >/dev/null 2>&1; then
    echo "PASS $name (verified)"; passed=$((passed+1))
  else
    echo "FAIL $name: known-good proof was rejected (exit $?)"; failed=$((failed+1))
  fi
}

# expect_reject <name> <mmb> <mm0-or-/dev/null> : bad proof must be REJECTED (non-zero exit)
expect_reject() {
  local name="$1" mmb="$2" mm0="$3"
  if "$BIN" "$mmb" < "$mm0" >/dev/null 2>&1; then
    echo "FAIL $name: corrupted proof was ACCEPTED (should be rejected)"; failed=$((failed+1))
  else
    echo "PASS $name (rejected)"; passed=$((passed+1))
  fi
}

# ── positive: known-good proofs verify ──────────────────────────────────────
expect_verify "peano.mmb verifies against peano.mm0" "$T/peano.mmb" "$T/peano.mm0"
expect_verify "empty.mmb verifies"                   "$T/empty.mmb" /dev/null

# ── negative: corrupted / truncated proofs are rejected ─────────────────────
CORRUPT="$(mktemp)"; TRUNC="$(mktemp)"
trap 'rm -f "$CORRUPT" "$TRUNC"' EXIT
# clobber the term-table region of a valid header -> "Term table out of range"
cp "$T/peano.mmb" "$CORRUPT"
printf '\xff\xff\xff\xff' | dd of="$CORRUPT" bs=1 seek=8 count=4 conv=notrunc 2>/dev/null
expect_reject "corrupted peano.mmb header is rejected" "$CORRUPT" "$T/peano.mm0"
# a truncated file (first 200 bytes) has no valid tables
head -c 200 "$T/peano.mmb" > "$TRUNC"
expect_reject "truncated peano.mmb is rejected" "$TRUNC" /dev/null

emit_ctrf "mm0-c" "$passed" "$failed" 0
