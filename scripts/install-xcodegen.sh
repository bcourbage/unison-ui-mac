#!/usr/bin/env bash
# Single source of truth for the pinned, checksum-verified XcodeGen.
#
# It installs into an IGNORED, REPOSITORY-LOCAL path (.tools/xcodegen/<version>/)
# — never /usr/local, never with sudo, and it does NOT touch the developer's
# global or Homebrew xcodegen. The generation step invokes that exact binary
# (via `--print-bin`), so a different `xcodegen` earlier on PATH (e.g. a Homebrew
# 2.46.0 on Apple Silicon, where /opt/homebrew/bin precedes /usr/local/bin)
# cannot shadow the pinned copy.
#
# Every generation path consults THIS file for the approved version + checksum:
#   - local generation ......... scripts/generate-project.sh (uses --print-bin)
#   - CI ...................... .github/workflows/ci.yml
#   - release ................ .github/workflows/release.yml
#   - blob rebuild ........... .github/workflows/vendor-blob.yml
#
# To bump XcodeGen, change XCODEGEN_VERSION + XCODEGEN_ZIP_SHA256 here ONLY (a
# deliberate, reviewed change — re-diff the generated project), never casually.
#
# Usage:
#   scripts/install-xcodegen.sh                 # install into .tools/ (idempotent)
#   scripts/install-xcodegen.sh --print-version # pinned version
#   scripts/install-xcodegen.sh --print-sha     # pinned zip sha256
#   scripts/install-xcodegen.sh --print-bin     # absolute path to the pinned binary
set -euo pipefail

XCODEGEN_VERSION="2.44.1"
# sha256 of https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip
XCODEGEN_ZIP_SHA256="a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73"

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/.tools/xcodegen/$XCODEGEN_VERSION"
bin="$dest/bin/xcodegen"

case "${1:-install}" in
  --print-version) printf '%s\n' "$XCODEGEN_VERSION"; exit 0 ;;
  --print-sha)     printf '%s\n' "$XCODEGEN_ZIP_SHA256"; exit 0 ;;
  --print-bin)     printf '%s\n' "$bin"; exit 0 ;;
  install)         ;;
  *) echo "usage: $0 [install|--print-version|--print-sha|--print-bin]" >&2; exit 2 ;;
esac

# Idempotent: already installed at the pinned version.
if [ -x "$bin" ] && [ "$("$bin" --version 2>/dev/null | awk '{print $2}')" = "$XCODEGEN_VERSION" ]; then
  echo "xcodegen $XCODEGEN_VERSION already present at $bin"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

echo "${XCODEGEN_ZIP_SHA256}  $work/xcodegen.zip" | shasum -a 256 -c - \
  || { echo "::error::XcodeGen zip failed SHA-256 verification (supply-chain guard)" >&2; exit 1; }

unzip -q "$work/xcodegen.zip" -d "$work"

# The binary resolves its resources from ../share, so colocate bin/ and share/
# under $dest. No sudo, no PATH mutation, no global install.
rm -rf "$dest"
mkdir -p "$dest"
cp -R "$work/xcodegen/bin" "$work/xcodegen/share" "$dest/"

got="$("$bin" --version | awk '{print $2}')"
echo "xcodegen: $got  (installed at $bin)"
[ "$got" = "$XCODEGEN_VERSION" ] \
  || { echo "::error::installed xcodegen $got != pinned $XCODEGEN_VERSION" >&2; exit 1; }
