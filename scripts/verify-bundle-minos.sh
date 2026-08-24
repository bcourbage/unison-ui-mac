#!/bin/sh
# verify-bundle-minos.sh — assert every Mach-O in a built .app targets the
# project's macOS deployment floor, so the FINISHED product genuinely runs on the
# baseline OS.
#
# SF7: the app is built on a host whose Xcode/SDK and OCaml runtime may be newer
# than the advertised floor (Release builds run on macOS 26 with Xcode 26). A
# Mach-O tagged for a NEWER macOS silently raises the real minimum: it either
# emits deployment-version linker warnings (the OCaml runtime case, fixed by
# building OCaml for the target) or — for our own compiled code — refuses to load
# on the baseline OS. Checking the finished bundle proves the guarantee for the
# EXACT signed/packaged bytes we ship, independent of how they were built.
#
# Two-tier rule (checks LC_BUILD_VERSION minos, or the legacy LC_VERSION_MIN_MACOSX):
#   * NO Mach-O — ours or a vendored framework — may declare a floor GREATER than
#     the target. That is the actual "runs on macOS <target>" guarantee.
#   * Our OWN binaries (directly in Contents/MacOS/) must be EXACTLY the target —
#     a stricter check that our binaries were built with the configured deployment
#     target and nothing bumped our floor.
#     Vendored code (Sparkle) legitimately ships a LOWER floor (it supports older
#     macOS) and is only held to the not-greater rule.
#
# Usage: verify-bundle-minos.sh <path-to.app> [expected-macos-version]
#   expected defaults to project.yml options.deploymentTarget.macOS.
#
# Fails closed: a bundle with zero Mach-O binaries, an unreadable target, or any
# nonconforming binary exits nonzero.
set -eu

app="${1:?usage: verify-bundle-minos.sh <path-to.app> [expected-version]}"
here="$(cd "$(dirname "$0")/.." && pwd)"

expected="${2:-}"
if [ -z "$expected" ]; then
    # Same reader the Makefile's DEPLOY_TARGET uses (options.deploymentTarget.macOS).
    expected="$(awk '/deploymentTarget:/{f=1} f&&/macOS:/{gsub(/[" ]/,""); split($0,a,":"); print a[2]; exit}' "$here/project.yml")"
fi
[ -n "$expected" ] || { echo "error: could not determine expected macOS version" >&2; exit 1; }

[ -d "$app" ] || { echo "error: app bundle not found: $app" >&2; exit 1; }

# The app's REAL main executable, from Info.plist. A count-only check would pass a
# bundle that lost its main binary but kept a vendored framework (a real packaging
# regression), so require CFBundleExecutable to name an existing regular Mach-O in
# Contents/MacOS — the file that must actually run on the baseline OS. It is then
# held to the strict "== target" rule by the loop below (it lives in Contents/MacOS).
plist="$app/Contents/Info.plist"
[ -f "$plist" ] || { echo "error: no Info.plist at $plist" >&2; exit 1; }
main_exec="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
[ -n "$main_exec" ] || { echo "error: Info.plist has no CFBundleExecutable" >&2; exit 1; }
main_path="$app/Contents/MacOS/$main_exec"
main_rel="Contents/MacOS/$main_exec"
[ -f "$main_path" ] || { echo "error: main executable $main_rel (CFBundleExecutable) is missing" >&2; exit 1; }
case "$(file -b "$main_path" 2>/dev/null)" in
    *Mach-O*) : ;;
    *) echo "error: main executable $main_rel is not a Mach-O binary" >&2; exit 1 ;;
esac

echo "Verifying Mach-O deployment floors in $(basename "$app") (target $expected, main $main_exec) ..."

# gt A B: true (exit 0) iff version A is strictly greater than version B, by
# dotted-numeric order (10.13 < 11.0 < 15.0 < 26.0). `sort -V` orders them; A>B
# iff A is not <= B, i.e. A is not the first line when {A,B} is version-sorted
# AND A != B.
gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}

# Enumerate every regular file, keep the Mach-O ones. `file` is reliable here and
# avoids assuming a fixed bundle layout (main binary, Sparkle's XPC services,
# Autoupdate, the framework binary, ...).
fail=0
count=0
main_seen=0
# Use a temp file rather than a pipeline so `fail`/`count` survive (a `while` in a
# pipe runs in a subshell under POSIX sh).
list="$(mktemp)"
trap 'rm -f "$list"' EXIT
find "$app" -type f -print > "$list"

while IFS= read -r f; do
    case "$(file -b "$f" 2>/dev/null)" in
        *Mach-O*) : ;;
        *) continue ;;
    esac
    count=$((count + 1))
    rel="${f#"$app"/}"
    [ "$rel" = "$main_rel" ] && main_seen=1
    # Our own binaries live directly in Contents/MacOS/; anything under a nested
    # bundle (Frameworks/…, *.xpc, *.app) is vendored (Sparkle) and held only to
    # the not-greater rule.
    ours=0
    case "$rel" in
        Contents/MacOS/*) ours=1 ;;
    esac

    # A fat binary lists one build-version per slice; a thin one lists one. minos
    # appears under both LC_BUILD_VERSION ("minos X.Y") and, on older objects,
    # LC_VERSION_MIN_MACOSX ("version X.Y"); otool -l prints "minos" for the former
    # and "version" for the latter, so capture both.
    vers="$(otool -l "$f" 2>/dev/null | awk '
        /LC_BUILD_VERSION/    {b=1; next}
        /LC_VERSION_MIN_MACOSX/ {v=1; next}
        b && /minos/   {print $2; b=0}
        v && /version/ {print $2; v=0}
    ' | sort -u)"
    if [ -z "$vers" ]; then
        echo "  FAIL: $rel declares no macOS minimum version" >&2
        fail=1
        continue
    fi

    shown="$(printf '%s' "$vers" | paste -sd, -)"
    bad=0
    for v in $vers; do
        if gt "$v" "$expected"; then
            echo "  FAIL: $rel minos $shown exceeds target $expected (would not run on $expected)" >&2
            bad=1
        elif [ "$ours" -eq 1 ] && [ "$v" != "$expected" ]; then
            echo "  FAIL: $rel minos $shown != target $expected (our own binary must be exactly the target)" >&2
            bad=1
        fi
    done
    if [ "$bad" -ne 0 ]; then
        fail=1
    elif [ "$ours" -eq 1 ]; then
        echo "  OK:   $rel minos $shown (ours, == target)"
    else
        echo "  OK:   $rel minos $shown (vendored, <= target)"
    fi
done < "$list"

if [ "$count" -eq 0 ]; then
    echo "error: no Mach-O binaries found in $app — nothing was verified" >&2
    exit 1
fi

# Defensive: the up-front check guarantees the main executable exists and is
# Mach-O, so the enumeration must have reached it. If not, the bundle layout is
# inconsistent — fail rather than report success over a partial scan.
if [ "$main_seen" -ne 1 ]; then
    echo "error: main executable $main_rel was not among the scanned Mach-O binaries" >&2
    exit 1
fi

if [ "$fail" -ne 0 ]; then
    echo "error: one or more Mach-O binaries do not satisfy the macOS $expected floor" >&2
    exit 1
fi

echo "All $count Mach-O binaries satisfy the macOS $expected floor (main $main_exec == $expected)."
