#!/bin/bash
# Compare UnisonPreferenceCatalog.swift with what the built engine prints for
# `unison -help`, in both directions:
#
#   1. the set of names -help prints must EQUAL the catalog's help-visible
#      names (every registration not flagged .internal or .pseudo), so a
#      preference the engine added or removed fails this check;
#   2. every -help line's argument placeholder must agree with the catalog
#      kind: .bool takes no argument, .int takes `n`, every other kind takes
#      `xxx`;
#   3. every name -help marks "command-line only" carries .commandLineOnly.
#
# -help cannot show internal registrations, alias targets, whether an `xxx`
# preference is a list or a scalar, or custom value grammars; those parts of
# the table rest on reading the upstream source at the vendored commit and
# must be re-derived by hand when the blob is bumped.
#
# Usage: scripts/check-pref-catalog.sh <path/to/unison-ui-mac.app>
set -euo pipefail

app=${1:?usage: $0 <unison-ui-mac.app>}
cltool="$app/Contents/MacOS/cltool"
catalog="$(cd "$(dirname "$0")/.." && pwd)/Sources/App/UnisonPreferenceCatalog.swift"
[ -x "$cltool" ] || { echo "check-pref-catalog: no launcher at $cltool" >&2; exit 2; }
[ -r "$catalog" ] || { echo "check-pref-catalog: no catalog at $catalog" >&2; exit 2; }

help=$("$cltool" -help 2>&1 || true)
# name<TAB>placeholder. Uarg prints `xxx` for a string-like argument and `n`
# for an integer; an option without an argument is followed directly by its
# description (after one space when the name is long), so only those two
# words count as placeholders.
help_rows=$(printf '%s\n' "$help" | grep -E '^   -[A-Za-z0-9_-]+' \
  | sed -E 's/^   -([A-Za-z0-9_-]+)( (xxx|n))?( .*)?$/\1\t\3/' | sort -u)
help_count=$(printf '%s\n' "$help_rows" | grep -c . || true)
if [ "$help_count" -lt 50 ]; then
  echo "check-pref-catalog: only $help_count option names parsed from -help; output was:" >&2
  printf '%s\n' "$help" | head -20 >&2
  exit 1
fi

# name<TAB>kind<TAB>flags from the Swift table (one registration per line).
cat_rows=$(grep -E '^        "[A-Za-z0-9_-]+": \(\.' "$catalog" \
  | sed -E 's/^        "([^"]+)": \(\.([a-z]+), (.*)\),$/\1\t\2\t\3/' | sort -u)
cat_count=$(printf '%s\n' "$cat_rows" | grep -c . || true)
if [ "$cat_count" -lt 50 ]; then
  echo "check-pref-catalog: only $cat_count registrations parsed from $catalog" >&2
  exit 1
fi

status=0
help_names=$(printf '%s\n' "$help_rows" | cut -f1 | sort -u)
visible_names=$(printf '%s\n' "$cat_rows" | awk -F'\t' '$3 !~ /internal/ && $3 !~ /pseudo/ {print $1}' | sort -u)

for n in $(comm -23 <(printf '%s\n' "$help_names") <(printf '%s\n' "$visible_names")); do
  echo "check-pref-catalog: -help lists \"$n\" but the catalog has no help-visible entry for it" >&2
  status=1
done
for n in $(comm -13 <(printf '%s\n' "$help_names") <(printf '%s\n' "$visible_names")); do
  echo "check-pref-catalog: catalog entry \"$n\" is not internal yet -help does not list it (removed by the engine?)" >&2
  status=1
done

# Placeholder vs kind.
while IFS=$'\t' read -r n placeholder; do
  [ -n "$n" ] || continue
  kind=$(printf '%s\n' "$cat_rows" | awk -F'\t' -v n="$n" '$1==n {print $2}')
  [ -n "$kind" ] || continue   # already reported above
  case "$kind:$placeholder" in
    bool:) ;;
    int:n) ;;
    string:xxx|list:xxx|custom:xxx) ;;
    *) echo "check-pref-catalog: \"$n\" is .$kind in the catalog but -help shows argument '${placeholder:-<none>}'" >&2; status=1 ;;
  esac
done <<< "$help_rows"

# "command-line only" wording vs flag.
while read -r n; do
  [ -n "$n" ] || continue
  if ! printf '%s\n' "$cat_rows" | awk -F'\t' -v n="$n" '$1==n && $3 ~ /commandLineOnly/ {found=1} END {exit !found}'; then
    echo "check-pref-catalog: -help marks \"$n\" command-line only; the catalog does not" >&2
    status=1
  fi
done < <(printf '%s\n' "$help" | grep -iE 'command.line only' | grep -oE '^   -[A-Za-z0-9_-]+' | sed 's/^ *-//')

if [ "$status" -eq 0 ]; then
  echo "check-pref-catalog: $help_count -help names equal the catalog's help-visible names; argument placeholders agree with kinds"
fi
exit $status
