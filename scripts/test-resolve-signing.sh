#!/bin/sh
# test-resolve-signing.sh — deterministic matrix test for resolve-signing.sh
# and select-signing.sh.
#
# Drives the resolver through its full decision matrix WITHOUT a live keychain,
# by feeding canned `security` output via the SIGN_RESOLVER_*_CMD test seams.
# Fixture certificates are generated with openssl so the multiple-identity /
# same-record and manual-verification cases are genuinely exercised (real OU
# fields extracted by the same openssl path production uses). Exits non-zero if
# any case fails.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
resolver="$here/resolve-signing.sh"
selector="$here/select-signing.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
pass=0

# --- fixture certs: three Apple Development identities, different teams -------
H1="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
H2="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
H3="CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
TEAM1="TEAMAAAA11"
TEAM2="TEAMBBBB22"
TEAM3="TEAMCCCC33"
# A legitimate but shell-hostile identity name (spaces, apostrophe, parens).
HOSTILE_NAME="Apple Development: Pat O'Brien (dev)"

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k1" -out "$tmp/c1.pem" -days 1 \
    -subj "/CN=Apple Development: one/OU=$TEAM1/O=Test/C=US" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k2" -out "$tmp/c2.pem" -days 1 \
    -subj "/CN=Apple Development: two/OU=$TEAM2/O=Test/C=US" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k3" -out "$tmp/c3.pem" -days 1 \
    -subj "/CN=Apple Development: three/OU=$TEAM3/O=Test/C=US" >/dev/null 2>&1

cat > "$tmp/ident_two.txt" <<EOF
  1) $H1 "Apple Development: one ($TEAM1)"
  2) $H2 "Apple Development: two ($TEAM2)"
     2 valid identities found
EOF

cat > "$tmp/ident_one.txt" <<EOF
  1) $H1 "Apple Development: one ($TEAM1)"
     1 valid identities found
EOF

# identity #3 carries a shell-hostile display name
cat > "$tmp/ident_hostile.txt" <<EOF
  1) $H3 "$HOSTILE_NAME"
     1 valid identities found
EOF

: > "$tmp/ident_none.txt"

# certs fixture: put H2's block FIRST so an independent "first certificate"
# lookup would wrongly pair identity #1 (H1) with team2. A correct resolver
# matches H1 to ITS OWN cert block and returns team1.
{
    printf 'SHA-256 hash: 00\nSHA-1 hash: %s\n' "$H2"; cat "$tmp/c2.pem"
    printf 'SHA-256 hash: 00\nSHA-1 hash: %s\n' "$H1"; cat "$tmp/c1.pem"
    printf 'SHA-256 hash: 00\nSHA-1 hash: %s\n' "$H3"; cat "$tmp/c3.pem"
} > "$tmp/certs.txt"

# run the RESOLVER directly. args: CONFIG CI SIGN_IDENTITY DEV_TEAM identities-file
run() {
    env -i PATH="$PATH" \
        CONFIG="$1" CI="$2" SIGN_IDENTITY="$3" DEV_TEAM="$4" \
        SIGN_RESOLVER_IDENTITIES_CMD="cat $5" \
        SIGN_RESOLVER_CERTS_CMD="cat $tmp/certs.txt" \
        sh "$resolver"
}

check() { # check <label> <actual> <expected>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf 'PASS  %s\n' "$1"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n      expected: [%s]\n      actual:   [%s]\n' "$1" "$3" "$2"
    fi
}

# line-oriented parse — IDENTICAL to what the Makefile does on the resolver /
# selector output (proves the two-line contract survives hostile values).
id_of()   { printf '%s\n' "$1" | sed -n '1p'; }
team_of() { printf '%s\n' "$1" | sed -n '2p'; }

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

# 5. local + CI Release -> ad-hoc (even with a valid identity / override)
o="$(run Release '' '' '' "$tmp/ident_one.txt")"
check "local Release: identity" "$(id_of "$o")" "-"
o="$(run Release 1 '' '' "$tmp/ident_one.txt")"
check "CI Release: identity" "$(id_of "$o")" "-"
o="$(run Release '' "$H1" "$TEAM1" "$tmp/ident_one.txt")"
check "Release ignores verified override: identity" "$(id_of "$o")" "-"

# 6. manual ad-hoc override
o="$(run Debug '' '-' '' "$tmp/ident_one.txt")"
check "manual SIGN_IDENTITY=-: identity" "$(id_of "$o")" "-"

# 7. manual override VERIFIED against a keychain record (hash selector)
o="$(run Debug '' "$H1" "$TEAM1" "$tmp/ident_one.txt")"
check "verified manual (hash): identity" "$(id_of "$o")" "$H1"
check "verified manual (hash): team"     "$(team_of "$o")" "$TEAM1"

# 8. manual override MISMATCH (right identity, wrong team) -> ad-hoc, NOT pass-through
o="$(run Debug '' "$H1" "$TEAM2" "$tmp/ident_one.txt")"
check "mismatched manual pair: identity" "$(id_of "$o")" "-"

# 9. manual override with an unknown identity -> ad-hoc
o="$(run Debug '' "DEADBEEF" "$TEAM1" "$tmp/ident_one.txt")"
check "unknown manual identity: identity" "$(id_of "$o")" "-"

# 10. incomplete overrides -> ad-hoc (never a partial pair)
o="$(run Debug '' "$H1" '' "$tmp/ident_one.txt")"
check "identity without team -> ad-hoc" "$(id_of "$o")" "-"
o="$(run Debug '' '' "$TEAM1" "$tmp/ident_one.txt")"
check "team without identity -> ad-hoc" "$(id_of "$o")" "-"

# 11. stale/keyless cert must not participate: certs.txt has Apple Development
#     certs but there are no VALID identities -> ad-hoc
o="$(run Debug '' '' '' "$tmp/ident_none.txt")"
check "keyless cert ignored (no valid identity): identity" "$(id_of "$o")" "-"

# 12. shell-hostile but LEGITIMATE identity name (spaces/apostrophe/parens),
#     verified by NAME selector -> passes through AND round-trips through the
#     Makefile's line parse byte-for-byte.
o="$(run Debug '' "$HOSTILE_NAME" "$TEAM3" "$tmp/ident_hostile.txt")"
check "hostile-but-legit name: identity round-trips" "$(id_of "$o")" "$HOSTILE_NAME"
check "hostile-but-legit name: team"                 "$(team_of "$o")" "$TEAM3"

# 13. hostile chars that are shell metacharacters must not execute — a `$(...)`
#     / `;` laden value simply fails verification (not in keychain) -> ad-hoc,
#     and nothing is executed (the sentinel file must not be created).
rm -f "$tmp/pwned"
o="$(run Debug '' '$(touch '"$tmp"'/pwned); rm -rf x' "$TEAM1" "$tmp/ident_one.txt")"
check "shell-metachar identity: identity -> ad-hoc" "$(id_of "$o")" "-"
if [ -e "$tmp/pwned" ]; then
    fail=$((fail + 1)); printf 'FAIL  shell-metachar identity executed a command!\n'
else
    pass=$((pass + 1)); printf 'PASS  shell-metachar identity did not execute\n'
fi

# 14. newline in a value cannot corrupt the two-line contract: an embedded
#     newline in SIGN_IDENTITY fails verification -> safe ad-hoc, well-formed.
nlid="$(printf 'line1\nline2')"
o="$(run Debug '' "$nlid" "$TEAM1" "$tmp/ident_one.txt")"
check "newline identity: safe ad-hoc" "$(id_of "$o")" "-"

# --- select-signing.sh adapter: fail-loud on resolver error/malformed --------

# 15. selector passes through a normal (ad-hoc) decision with exit 0
out="$(SIGN_RESOLVER="$resolver" env CONFIG=Release sh "$selector"; echo "rc=$?")"
rc="$(printf '%s\n' "$out" | sed -n 's/^rc=//p')"
check "selector: policy ad-hoc exits 0" "$rc" "0"

# 16. selector FAILS LOUDLY on a nonzero resolver exit
cat > "$tmp/stub_fail.sh" <<'EOF'
#!/bin/sh
echo "boom" >&2
exit 3
EOF
chmod +x "$tmp/stub_fail.sh"
SIGN_RESOLVER="$tmp/stub_fail.sh" sh "$selector" >/dev/null 2>&1
check "selector: nonzero resolver exit is fatal" "$?" "1"

# 17. selector FAILS LOUDLY on malformed (empty) resolver output
cat > "$tmp/stub_empty.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/stub_empty.sh"
SIGN_RESOLVER="$tmp/stub_empty.sh" sh "$selector" >/dev/null 2>&1
check "selector: malformed (empty) output is fatal" "$?" "1"

# 18. selector accepts well-formed output and re-emits it
cat > "$tmp/stub_ok.sh" <<'EOF'
#!/bin/sh
printf '%s\n%s\n' "IDVAL" "TEAMVAL"
EOF
chmod +x "$tmp/stub_ok.sh"
o="$(SIGN_RESOLVER="$tmp/stub_ok.sh" sh "$selector")"
check "selector: well-formed identity" "$(id_of "$o")" "IDVAL"
check "selector: well-formed team"     "$(team_of "$o")" "TEAMVAL"

echo "-----------------------------------------------"
echo "resolve-signing matrix: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
