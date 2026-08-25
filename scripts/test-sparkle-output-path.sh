#!/bin/sh
# test-sparkle-output-path.sh — sparkle-appcast.sh must validate the appcast that
# generate_appcast actually wrote, for EVERY output-path form generate_appcast
# accepts: separated (-o FILE, --output-path FILE) and joined (--output-path=FILE,
# -oFILE). A form the wrapper doesn't recognize would leave it checking the default
# path and either fail closed on a correct run or bless the wrong file.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/sparkle-appcast.sh"
# A known-good appcast (one signed enclosure) so the wrapper's downstream
# verify-appcast-signatures.sh passes — isolating the path-resolution behaviour.
good_feed="$here/fixtures/appcast/signed.xml"
fail=0
[ -f "$good_feed" ] || { echo "missing fixture: $good_feed" >&2; exit 2; }

# A stub generate_appcast that honours the same output-path forms and writes the
# known-good appcast there (default: <updates-dir>/appcast.xml, its real default).
make_stub() {  # make_stub <bin-dir>
    mkdir -p "$1"
    cat > "$1/generate_appcast" <<STUB
#!/bin/sh
good="$good_feed"
STUB
    cat >> "$1/generate_appcast" <<'STUB'
out=""; prev=""; last=""
for a in "$@"; do
    case "$a" in --output-path=*) out="${a#*=}" ;; -o?*) out="${a#-o}" ;; esac
    case "$prev" in -o|--output-path) out="$a" ;; esac
    prev="$a"; last="$a"
done
[ -n "$out" ] || out="$last/appcast.xml"   # sparkle-appcast.sh passes the dir last
cat "$good" > "$out"
STUB
    chmod +x "$1/generate_appcast"
}

# run_case <desc> <expect-rc> <flag-args...>: the token @OUT@ in the args is
# replaced with a path inside the updates dir; the wrapper must exit 0 (found the
# written appcast) for a recognized form.
run_case() {
    desc="$1"; want="$2"; shift 2
    work="$(mktemp -d)"
    make_stub "$work/bin"
    updates="$work/updates"; mkdir -p "$updates"
    # Substitute @OUT@ -> $updates/custom.xml in each arg.
    args=""
    for a in "$@"; do
        a=$(printf '%s' "$a" | sed "s#@OUT@#$updates/custom.xml#g")
        args="$args $a"
    done
    # shellcheck disable=SC2086
    SPARKLE_BIN="$work/bin" "$script" "$updates" $args >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq "$want" ]; then result=PASS; else result=FAIL; fail=1; fi
    printf '  %-26s expect_rc=%s rc=%s  %s\n' "$desc" "$want" "$rc" "$result"
    rm -rf "$work"
}

echo "sparkle-appcast.sh output-path resolution:"
run_case "default (no flag)"          0
run_case "-o FILE (separated)"        0 -o @OUT@
run_case "--output-path FILE (sep)"   0 --output-path @OUT@
run_case "--output-path=FILE (joined)" 0 --output-path=@OUT@
run_case "-oFILE (joined)"            0 -o@OUT@

if [ "$fail" -ne 0 ]; then
    echo "SPARKLE OUTPUT-PATH TESTS FAILED" >&2
    exit 1
fi
echo "all sparkle output-path tests passed"
