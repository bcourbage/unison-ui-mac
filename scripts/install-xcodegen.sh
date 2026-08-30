#!/usr/bin/env bash
# Single source of truth for the pinned, checksum-verified XcodeGen.
#
# Every generation path consults THIS file for the approved version + checksum:
#   - local generation .......... scripts/generate-project.sh (version gate)
#   - CI ........................ .github/workflows/ci.yml
#   - release .................. .github/workflows/release.yml
#   - blob rebuild ............. .github/workflows/vendor-blob.yml
#
# To bump XcodeGen, change XCODEGEN_VERSION + XCODEGEN_ZIP_SHA256 here ONLY; do
# not reintroduce the literals into the workflows. A bump is a deliberate,
# reviewed change (the generated project must be re-diffed), never a casual one.
#
# Usage:
#   scripts/install-xcodegen.sh                 # download + verify + install (needs sudo)
#   scripts/install-xcodegen.sh --print-version # emit the pinned version
#   scripts/install-xcodegen.sh --print-sha     # emit the pinned zip sha256
set -euo pipefail

XCODEGEN_VERSION="2.44.1"
# sha256 of https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip
XCODEGEN_ZIP_SHA256="a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73"

case "${1:-install}" in
  --print-version) printf '%s\n' "$XCODEGEN_VERSION"; exit 0 ;;
  --print-sha)     printf '%s\n' "$XCODEGEN_ZIP_SHA256"; exit 0 ;;
  install)         ;;
  *) echo "usage: $0 [install|--print-version|--print-sha]" >&2; exit 2 ;;
esac

# --- install: pinned + SHA-256-verified, so a floating/compromised release
# cannot change the generated project between otherwise-identical commits. ---
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

echo "${XCODEGEN_ZIP_SHA256}  $work/xcodegen.zip" | shasum -a 256 -c - \
  || { echo "::error::XcodeGen zip failed SHA-256 verification (supply-chain guard)" >&2; exit 1; }

unzip -q "$work/xcodegen.zip" -d "$work"
sudo "$work/xcodegen/install.sh"

got="$(xcodegen --version | awk '{print $2}')"
echo "xcodegen: $got"
[ "$got" = "$XCODEGEN_VERSION" ] \
  || { echo "::error::xcodegen $got != pinned $XCODEGEN_VERSION" >&2; exit 1; }
