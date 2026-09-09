#!/bin/sh
# test-check-stock-zprofile.sh — tests for check-stock-zprofile.sh via its
# ZPROFILE_PATH / MACOS_MAJOR_OVERRIDE seams. No sw_vers dependence.
set -u

here=$(cd "$(dirname "$0")" && pwd)
gate="$here/check-stock-zprofile.sh"
fix="$here/fixtures"
fail=0
check() { if [ "$2" -eq 0 ]; then r=PASS; else r=FAIL; fail=1; fi; printf '  %-44s %s\n' "$1" "$r"; }

echo "check-stock-zprofile.sh:"

# The macOS 15 fixture compared against the macOS 15 fixture: matches.
ZPROFILE_PATH="$fix/stock-zprofile-macos15.txt" MACOS_MAJOR_OVERRIDE=15 "$gate" >/dev/null 2>&1
check "matching fixture passes" $?

# The macOS 26 text compared against the macOS 15 fixture: differs, must fail.
ZPROFILE_PATH="$fix/stock-zprofile-macos26.txt" MACOS_MAJOR_OVERRIDE=15 "$gate" >/dev/null 2>&1
[ "$?" -ne 0 ]
check "mismatch fails" $?

# A macOS major with no fixture is Manual setup, not a failure.
MACOS_MAJOR_OVERRIDE=99 "$gate" >/dev/null 2>&1
check "unknown major passes (Manual setup)" $?

# An unreadable /etc/zprofile for a known major fails, not a silent pass.
ZPROFILE_PATH="$here/does-not-exist-zprofile" MACOS_MAJOR_OVERRIDE=15 "$gate" >/dev/null 2>&1
[ "$?" -ne 0 ]
check "unreadable zprofile fails" $?

if [ "$fail" -ne 0 ]; then echo "TEST-CHECK-STOCK-ZPROFILE FAILED" >&2; exit 1; fi
echo "all check-stock-zprofile tests passed"
