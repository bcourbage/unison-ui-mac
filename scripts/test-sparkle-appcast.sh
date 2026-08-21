#!/bin/sh
# test-sparkle-appcast.sh — fixtures for verify-appcast-signatures.sh.
#
# Locks the per-enclosure signature check: an appcast passes only if EVERY
# <enclosure> carries its own non-empty EdDSA signature. The release-notes-sig
# case is the regression guard against the earlier global-count logic, which a
# signed release-notes link could mask.
set -u

here=$(cd "$(dirname "$0")" && pwd)
verify="$here/verify-appcast-signatures.sh"
fx="$here/fixtures/appcast"
fail=0

# expect <fixture> <pass|fail> <description>
expect() {
	fixture="$1"; want="$2"; desc="$3"
	"$verify" "$fx/$fixture" >/dev/null 2>&1
	rc=$?
	if [ "$want" = pass ]; then
		[ "$rc" -eq 0 ] && result=PASS || { result=FAIL; fail=1; }
	else
		[ "$rc" -ne 0 ] && result=PASS || { result=FAIL; fail=1; }
	fi
	printf '  %-22s expect=%-4s rc=%s  %s  (%s)\n' "$fixture" "$want" "$rc" "$result" "$desc"
}

echo "verify-appcast-signatures.sh:"
expect signed.xml            pass "one signed enclosure"
expect multi-signed.xml      pass "two signed enclosures"
expect unsigned.xml          fail "one unsigned enclosure"
expect mixed.xml             fail "one signed + one unsigned enclosure"
expect release-notes-sig.xml fail "unsigned enclosure, signed release-notes link (must not mask)"
expect no-enclosure.xml      fail "no enclosures at all"

if [ "$fail" -ne 0 ]; then
	echo "APPCAST VERIFIER TESTS FAILED" >&2
	exit 1
fi
echo "all appcast verifier tests passed"
