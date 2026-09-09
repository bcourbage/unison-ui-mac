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
major="${MACOS_MAJOR_OVERRIDE:-$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)}"
version="$(sw_vers -productVersion 2>/dev/null || echo '?')"
build="$(sw_vers -buildVersion 2>/dev/null || echo '?')"
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
