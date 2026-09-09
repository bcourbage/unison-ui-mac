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
match=$(grep -RInF \
	-e 'with administrator privileges' \
	-e 'AuthorizationExecuteWithPrivileges' \
	-e 'AuthorizationCreate' \
	-e 'SMAppService' \
	-e 'SMJobBless' \
	-e 'requestAuthorization(to:' \
	--include='*.swift' --include='*.c' --include='*.h' --include='*.m' \
	"$dir" 2>/dev/null) || true

if [ -n "$match" ]; then
	echo "check-no-elevation: FAIL — forbidden elevation identifiers in $dir:" >&2
	printf '%s\n' "$match" | sed 's/^/  /' >&2
	exit 1
fi

echo "check-no-elevation: OK — no known elevation identifiers in $dir"
