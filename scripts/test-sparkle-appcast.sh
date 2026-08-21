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
expect signed.xml                            pass "one signed enclosure"
expect multi-signed.xml                      pass "two signed enclosures"
expect alternate-prefix-correct-namespace.xml pass "non-'sparkle' prefix bound to the exact Sparkle URI"
expect delta-signed.xml                      pass "signed main + signed delta enclosure (sparkle:deltas)"
expect foreign-default-signed.xml            pass "foreign default-namespace enclosure, validly signed (Sparkle parses+accepts)"
expect unsigned.xml                          fail "one unsigned enclosure"
expect mixed.xml                             fail "one signed + one unsigned enclosure"
expect release-notes-sig.xml                 fail "unsigned enclosure, signed release-notes link (must not mask)"
expect foreign-namespace-signature.xml       fail "edSignature in a foreign namespace (Sparkle ignores it)"
expect unprefixed-signature.xml              fail "unprefixed edSignature (not in the Sparkle namespace)"
expect unrelated-enclosure.xml               fail "only a namespaced <evil:enclosure> — no real enclosure"
expect delta-unsigned.xml                    fail "signed main but UNSIGNED delta enclosure"
expect out-of-schema-signed-enclosure.xml    fail "signed enclosure under <channel><metadata> (Sparkle never parses it)"
expect nested-item-enclosure.xml             fail "signed enclosure under <item><metadata> (not a first-level child)"
expect main-item-default-namespace.xml       fail "unsigned main enclosure in a foreign default namespace (Sparkle parses by name)"
expect delta-default-namespace.xml           fail "unsigned delta enclosure in a foreign default namespace"
expect bad-shape-signature.xml               fail "signature present + namespaced but not 64-byte Ed25519 shape"
expect no-enclosure.xml                      fail "no enclosures at all"

if [ "$fail" -ne 0 ]; then
	echo "APPCAST VERIFIER TESTS FAILED" >&2
	exit 1
fi
echo "all appcast verifier tests passed"
