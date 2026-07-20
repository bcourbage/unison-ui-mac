#!/bin/sh
# test-resolve-signing.sh — deterministic matrix test for resolve-signing.sh.
#
# Drives the resolver through its full decision matrix WITHOUT a live keychain,
# by feeding canned `security` output via the SIGN_RESOLVER_*_CMD test seams.
# Fixture certificates are generated with openssl so the multiple-identity /
# same-record cases are genuinely exercised (real OU fields extracted by the
# same openssl path production uses). Exits non-zero if any case fails.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
resolver="$here/resolve-signing.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
pass=0

# --- fixture certs: two Apple Development identities, different teams --------
H1="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
H2="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
TEAM1="TEAMAAAA11"
TEAM2="TEAMBBBB22"

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k1" -out "$tmp/c1.pem" -days 1 \
    -subj "/CN=Apple Development: one/OU=$TEAM1/O=Test/C=US" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k2" -out "$tmp/c2.pem" -days 1 \
    -subj "/CN=Apple Development: two/OU=$TEAM2/O=Test/C=US" >/dev/null 2>&1

# identities fixture: identity #1 = H1/team1, identity #2 = H2/team2 (valid only)
cat > "$tmp/ident_two.txt" <<EOF
  1) $H1 "Apple Development: one ($TEAM1)"
  2) $H2 "Apple Development: two ($TEAM2)"
     2 valid identities found
EOF

cat > "$tmp/ident_one.txt" <<EOF
  1) $H1 "Apple Development: one ($TEAM1)"
     1 valid identities found
EOF

: > "$tmp/ident_none.txt"

# certs fixture: put H2's block FIRST so an independent "first certificate"
# lookup would wrongly pair identity #1 (H1) with team2. A correct resolver
# matches H1 to ITS OWN cert block and returns team1.
{
    printf 'SHA-256 hash: 00\nSHA-1 hash: %s\n' "$H2"; cat "$tmp/c2.pem"
    printf 'SHA-256 hash: 00\nSHA-1 hash: %s\n' "$H1"; cat "$tmp/c1.pem"
} > "$tmp/certs.txt"

# a keyless/stale cert present in the cert dump but NOT among valid identities
IDC="$tmp/ident_none.txt"   # no valid identities...
# ...even though certs.txt contains Apple Development certs (simulates stale/keyless)

run() { # run <CONFIG> <CI> <SIGN_IDENTITY> <DEV_TEAM> <identities_file>
    env -i PATH="$PATH" \
        CONFIG="$1" CI="$2" SIGN_IDENTITY="$3" DEV_TEAM="$4" \
        SIGN_RESOLVER_IDENTITIES_CMD="cat $5" \
        SIGN_RESOLVER_CERTS_CMD="cat $tmp/certs.txt" \
        sh "$resolver" 2>/dev/null
}

check() { # check <label> <actual> <expected>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf 'PASS  %s\n' "$1"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$3" "$2"
    fi
}

id_of()   { printf '%s\n' "$1" | sed -n "s/^RESOLVED_IDENTITY='\(.*\)'$/\1/p"; }
team_of() { printf '%s\n' "$1" | sed -n "s/^RESOLVED_TEAM='\(.*\)'$/\1/p"; }

# 1. local Debug, one valid identity -> that identity's hash + its own team
o="$(run Debug '' '' '' "$tmp/ident_one.txt")"
check "local Debug, one identity: identity" "$(id_of "$o")" "$H1"
check "local Debug, one identity: team"     "$(team_of "$o")" "$TEAM1"

# 2. local Debug, no identity -> ad-hoc
o="$(run Debug '' '' '' "$tmp/ident_none.txt")"
check "local Debug, no identity: identity" "$(id_of "$o")" "-"
check "local Debug, no identity: team"     "$(team_of "$o")" ""

# 3. multiple identities/teams -> first identity's hash AND its OWN team
#    (proves identity + team come from the SAME record, not independent lookups)
o="$(run Debug '' '' '' "$tmp/ident_two.txt")"
check "multi-identity: identity is #1's hash" "$(id_of "$o")" "$H1"
check "multi-identity: team is #1's OWN team" "$(team_of "$o")" "$TEAM1"

# 4. CI Debug -> ad-hoc
o="$(run Debug 1 '' '' "$tmp/ident_one.txt")"
check "CI Debug: identity" "$(id_of "$o")" "-"
check "CI Debug: team"     "$(team_of "$o")" ""

# 5. local Release -> ad-hoc (even with a valid identity available)
o="$(run Release '' '' '' "$tmp/ident_one.txt")"
check "local Release: identity" "$(id_of "$o")" "-"

# 6. CI Release -> ad-hoc
o="$(run Release 1 '' '' "$tmp/ident_one.txt")"
check "CI Release: identity" "$(id_of "$o")" "-"

# 7. Release ignores a manual identity override (still ad-hoc)
o="$(run Release '' MANUALID MANUALTEAM "$tmp/ident_one.txt")"
check "Release ignores override: identity" "$(id_of "$o")" "-"

# 8. manual ad-hoc override
o="$(run Debug '' '-' '' "$tmp/ident_one.txt")"
check "manual SIGN_IDENTITY=-: identity" "$(id_of "$o")" "-"

# 9. manual identity + team override (passthrough)
o="$(run Debug '' MANUALID MANUALTEAM "$tmp/ident_one.txt")"
check "manual override: identity" "$(id_of "$o")" "MANUALID"
check "manual override: team"     "$(team_of "$o")" "MANUALTEAM"

# 10. incomplete/inconsistent overrides -> ad-hoc (never a partial pair)
o="$(run Debug '' MANUALID '' "$tmp/ident_one.txt")"
check "identity without team -> ad-hoc" "$(id_of "$o")" "-"
o="$(run Debug '' '' MANUALTEAM "$tmp/ident_one.txt")"
check "team without identity -> ad-hoc" "$(id_of "$o")" "-"

# 11. stale/keyless cert must not participate: certs.txt has Apple Development
#     certs but there are no VALID identities -> ad-hoc
o="$(run Debug '' '' '' "$IDC")"
check "keyless cert ignored (no valid identity): identity" "$(id_of "$o")" "-"

echo "-----------------------------------------------"
echo "resolve-signing matrix: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
