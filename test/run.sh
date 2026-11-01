#!/bin/bash
# Runs every test_*.sh next to this file, each in its own bash process (the
# same bash that runs this file, so `/bin/bash test/run.sh` tests bash 3.2).
# A test file ends with "PASS <n>"; every failure is one "FAIL: …" line.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FIXTURES="$HERE/fixtures"
SHIM="$HERE/shim"
export ROOT FIXTURES SHIM
PASS=0; FAIL=0

assert_eq() { # assert_eq <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$3] got [$2]"; fi
}
assert_between() { # assert_between <name> <actual> <min> <max>
  if (( $2 >= $3 && $2 <= $4 )); then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected $3..$4 got [$2]"; fi
}
assert_contains() { # assert_contains <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: [$3] not found in: $2"; fi
}
assert_not_contains() { # assert_not_contains <name> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: [$3] found in: $2"; fi
}
export -f assert_eq assert_between assert_contains assert_not_contains

for t in "$HERE"/test_*.sh; do
  echo "== $(basename "$t")"
  out=$("$BASH" "$t" 2>&1); rc=$?
  echo "$out" | grep -v '^PASS [0-9]*$' || true
  p=$(echo "$out" | awk '/^PASS [0-9]+$/ { s += $2 } END { print s + 0 }')
  f=$(echo "$out" | grep -c '^FAIL:' || true)
  PASS=$((PASS + p)); FAIL=$((FAIL + f))
  if (( rc != 0 )); then FAIL=$((FAIL + 1)); echo "FAIL: $(basename "$t") exited $rc"; fi
done
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
