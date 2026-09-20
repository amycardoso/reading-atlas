#!/bin/sh
# Run the pure-Lua Reading Atlas suites and report a single pass/fail.
#
#   sh tests/run.sh            # uses `lua` from PATH
#   LUA=luajit sh tests/run.sh
#
# A suite FAILS if it exits non-zero or prints a "FAIL " marker line.
cd "$(dirname "$0")/.." || exit 2
LUA="${LUA:-lua}"

total=0
failed=0
for f in tests/_test_*.lua; do
    total=$((total + 1))
    out=$("$LUA" "$f" 2>&1)
    status=$?
    if [ $status -ne 0 ] || printf '%s' "$out" | grep -q '^FAIL '; then
        failed=$((failed + 1))
        printf 'FAIL  %s\n%s\n' "$f" "$out"
    else
        printf 'ok    %s  %s\n' "$f" "$(printf '%s' "$out" | tail -1)"
    fi
done

printf 'ran %d suites, %d failed\n' "$total" "$failed"
[ "$failed" -eq 0 ]
