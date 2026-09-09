#!/bin/sh
# check-stock-zprofile.sh — release gate: the machine's /etc/zprofile matches the
# embedded stock fixture for its macOS major, so the app recognizes it and can
# offer automatic zsh setup. Named for what it verifies: the recognized stock
# /etc/zprofile on the tested image.
#
# A macOS major with NO fixture is not a failure — those accounts use Manual
# setup, the design's intended refusal. A KNOWN major whose /etc/zprofile no
# longer matches the fixture IS a failure: Apple changed the file, so the fixture
# and the matching CommandLineSetupFileSelection.stockZprofileMacOS<major>
# constant must be re-measured before the app ships claiming to recognize it.
#
# ZPROFILE_PATH and MACOS_MAJOR_OVERRIDE exist for the self-test; production reads
# /etc/zprofile and `sw_vers`.
set -u

here=$(cd "$(dirname "$0")" && pwd)
fixtures="$here/fixtures"
zprofile="${ZPROFILE_PATH:-/etc/zprofile}"

# Establishing the OS is a precondition, kept distinct from its outcome. A failed
# OS query (sw_vers unavailable or erroring) is an infrastructure failure and
# must FAIL the gate: it is not the same as successfully identifying an
# unsupported major, and must never silently skip the check this gate promises.
# MACOS_MAJOR_OVERRIDE (used by the self-test) stands in for a successful
# identification.
if [ -n "${MACOS_MAJOR_OVERRIDE:-}" ]; then
	major="$MACOS_MAJOR_OVERRIDE"
	version="(major override $major)"
	build="(override)"
else
	if ! version="$(sw_vers -productVersion 2>/dev/null)" || [ -z "$version" ]; then
		echo "check-stock-zprofile: FAIL — could not determine the macOS version (sw_vers failed); the stock text cannot be verified" >&2
		exit 1
	fi
	build="$(sw_vers -buildVersion 2>/dev/null || echo '?')"
	major="$(printf '%s\n' "$version" | cut -d. -f1)"
	case "$major" in
		'' | *[!0-9]*)
			echo "check-stock-zprofile: FAIL — could not parse a macOS major from '$version'; the stock text cannot be verified" >&2
			exit 1
			;;
	esac
fi
echo "check-stock-zprofile: macOS $version ($build), major $major"

fixture="$fixtures/stock-zprofile-macos$major.txt"
if [ ! -f "$fixture" ]; then
	echo "check-stock-zprofile: no stock fixture for macOS $major; accounts on this OS use Manual setup (intended)."
	exit 0
fi
if [ ! -r "$zprofile" ]; then
	echo "check-stock-zprofile: FAIL — $zprofile is not readable; the stock text cannot be verified" >&2
	exit 1
fi
if cmp -s "$zprofile" "$fixture"; then
	echo "check-stock-zprofile: OK — $zprofile matches the recognized macOS $major stock text"
	exit 0
fi

echo "check-stock-zprofile: FAIL — $zprofile differs from the recognized macOS $major stock text." >&2
echo "  Re-measure it, update scripts/fixtures/stock-zprofile-macos$major.txt AND the" >&2
echo "  CommandLineSetupFileSelection.stockZprofileMacOS$major constant, then re-run." >&2
diff "$fixture" "$zprofile" 2>&1 | sed 's/^/  /' >&2
exit 1
