#!/bin/sh
# test-check-no-elevation.sh — tests for check-no-elevation.sh, the "known
# elevation APIs absent" release gate. No Xcode; shell only.
set -u

here=$(cd "$(dirname "$0")" && pwd)
gate="$here/check-no-elevation.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then r=PASS; else r=FAIL; fail=1; fi; printf '  %-46s %s\n' "$1" "$r"; }

echo "check-no-elevation.sh:"

# Clean source passes.
mkdir -p "$tmp/clean"
printf 'import Foundation\nlet x = 1\n' > "$tmp/clean/a.swift"
"$gate" "$tmp/clean" >/dev/null 2>&1
check "clean source passes" $?

# Each forbidden identifier is caught.
i=0
for id in \
	"with administrator privileges" \
	"AuthorizationExecuteWithPrivileges" \
	"AuthorizationCreate" \
	"SMAppService" \
	"SMJobBless" \
	"requestAuthorization(to:"
do
	i=$((i + 1))
	d="$tmp/bad$i"
	mkdir -p "$d"
	printf 'let s = "%s"\n' "$id" > "$d/x.swift"
	"$gate" "$d" >/dev/null 2>&1
	[ "$?" -ne 0 ]
	check "catches: $id" $?
done

# Only source files are scanned; the same string in a doc is ignored.
mkdir -p "$tmp/md"
printf 'SMJobBless mentioned in documentation\n' > "$tmp/md/x.md"
"$gate" "$tmp/md" >/dev/null 2>&1
check "ignores non-source files" $?

# A missing directory is an error, not a silent pass.
"$gate" "$tmp/does-not-exist" >/dev/null 2>&1
[ "$?" -ne 0 ]
check "missing directory fails" $?

# A FAILED scan must fail the gate, not pass as "no matches": shadow grep with a
# stub that exits 2 (an error) and produces no stdout.
mkdir -p "$tmp/stub_grep"
printf '#!/bin/sh\nexit 2\n' > "$tmp/stub_grep/grep"
chmod +x "$tmp/stub_grep/grep"
PATH="$tmp/stub_grep:$PATH" "$gate" "$tmp/clean" >/dev/null 2>&1
[ "$?" -ne 0 ]
check "failed scan (grep exit 2) fails closed" $?

if [ "$fail" -ne 0 ]; then echo "TEST-CHECK-NO-ELEVATION FAILED" >&2; exit 1; fi
echo "all check-no-elevation tests passed"
