#!/bin/sh
# check-no-elevation.sh — release gate "known elevation APIs absent".
#
# Asserts that none of the known privilege-escalation identifiers appears anywhere
# in the app source. It proves those identifiers are absent, not that every
# elevation path is; code review covers the rest. See
# docs/command-line-setup-design.md, "Removed from the app".
#
# Usage: check-no-elevation.sh [source-dir]   (default: <repo>/Sources)
set -u

here=$(cd "$(dirname "$0")" && pwd)
dir="${1:-$here/../Sources}"

if [ ! -d "$dir" ]; then
	echo "check-no-elevation: source directory not found: $dir" >&2
	exit 1
fi

# Fixed strings (grep -F), matched across Swift, C, Objective-C and headers.
# grep's exit status decides, and the gate fails CLOSED: 0 = a match was found
# (identifiers present), 1 = no match (absence established), >=1 other = the scan
# itself failed (a file could not be read, a bad option), which must NOT be read
# as absence. stderr is captured so a scan failure is reported, not swallowed.
errfile=$(mktemp)
match=$(grep -RInF \
	-e 'with administrator privileges' \
	-e 'AuthorizationExecuteWithPrivileges' \
	-e 'AuthorizationCreate' \
	-e 'SMAppService' \
	-e 'SMJobBless' \
	-e 'requestAuthorization(to:' \
	--include='*.swift' --include='*.c' --include='*.h' --include='*.m' \
	"$dir" 2>"$errfile")
status=$?

if [ "$status" -eq 0 ]; then
	echo "check-no-elevation: FAIL — forbidden elevation identifiers in $dir:" >&2
	printf '%s\n' "$match" | sed 's/^/  /' >&2
	rm -f "$errfile"
	exit 1
elif [ "$status" -ne 1 ]; then
	echo "check-no-elevation: FAIL — the scan did not complete (grep exit $status); absence not established" >&2
	sed 's/^/  /' "$errfile" >&2
	rm -f "$errfile"
	exit 1
fi

rm -f "$errfile"
echo "check-no-elevation: OK — no known elevation identifiers in $dir"
