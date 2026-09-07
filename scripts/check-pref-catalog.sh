#!/bin/bash
# Compare UnisonPreferenceCatalog.swift with the preferences the built engine
# prints for `unison -help`. Every name the engine lists must be in the
# catalog, and every name the engine marks "command-line only" must be
# flagged commandLineOnly. Fails when a vendored-blob bump changes the
# preference set without the catalog following.
#
# Usage: scripts/check-pref-catalog.sh <path/to/unison-ui-mac.app>
set -euo pipefail

app=${1:?usage: $0 <unison-ui-mac.app>}
cltool="$app/Contents/MacOS/cltool"
catalog="$(cd "$(dirname "$0")/.." && pwd)/Sources/App/UnisonPreferenceCatalog.swift"
[ -x "$cltool" ] || { echo "check-pref-catalog: no launcher at $cltool" >&2; exit 2; }
[ -r "$catalog" ] || { echo "check-pref-catalog: no catalog at $catalog" >&2; exit 2; }

help=$("$cltool" -help 2>&1 || true)
names=$(printf '%s\n' "$help" | grep -oE '^ {3}-[A-Za-z0-9_-]+' | sed 's/^ *-//' | sort -u)
count=$(printf '%s\n' "$names" | grep -c . || true)
if [ "$count" -lt 50 ]; then
  echo "check-pref-catalog: only $count option names parsed from -help; output was:" >&2
  printf '%s\n' "$help" | head -20 >&2
  exit 1
fi

status=0
for n in $names; do
  if ! grep -qE "^        \"$n\": \(" "$catalog" && ! grep -qE "^        \"$n\": \"" "$catalog"; then
    echo "check-pref-catalog: -help lists \"$n\" but the catalog does not" >&2
    status=1
  fi
done

# Names whose -help line says "command-line only" must carry the flag.
while read -r n; do
  [ -n "$n" ] || continue
  if ! grep -E "^        \"$n\": \(" "$catalog" | grep -q 'commandLineOnly'; then
    echo "check-pref-catalog: -help marks \"$n\" command-line only; the catalog does not" >&2
    status=1
  fi
done < <(printf '%s\n' "$help" | grep -iE 'command.line only' | grep -oE '^ {3}-[A-Za-z0-9_-]+' | sed 's/^ *-//')

if [ "$status" -eq 0 ]; then
  echo "check-pref-catalog: $count -help names all present in the catalog"
fi
exit $status
