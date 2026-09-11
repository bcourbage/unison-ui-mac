#!/usr/bin/env bash
# Reproduce the parser-variant engine prototype and its evidence.
# See docs/cli-session-parser-report.md.
#
# Unlike the loadStrings adapter spike, this one edits engine source: a small,
# backward-compatible extension to the command-line parser (Uarg.parseArgv,
# Prefs.parseCmdLineArgs) that accepts an explicit per-session argument vector
# and RAISES instead of exiting. The change is carried as a patch next to this
# script. The script applies it to a pristine tree, builds the vendored engine
# objects on the repository's own OCaml path (unison/src/Makefile.OCaml, same as
# `make vendor-blob`; no opam/dune), links the prototype, runs every asserted
# case, then restores the four patched files. Exits non-zero if any assertion
# fails.
#
# It restores ONLY the four files it patches, via `git checkout`, so unrelated
# local modifications in the unison working tree are left untouched.
#
# Usage:  UNISON_SRC=/path/to/unison/src docs/spikes/run-cli-session-parser-prototype.sh
set -euo pipefail

UNISON_SRC="${UNISON_SRC:-$HOME/Documents/Sources/unison/src}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROTO="$HERE/cli-session-parser-prototype.ml"
PATCH="$HERE/cli-session-parser.patch"
[ -d "$UNISON_SRC" ] || { echo "UNISON_SRC not found: $UNISON_SRC"; exit 2; }
[ -f "$PATCH" ] || { echo "patch not found: $PATCH"; exit 2; }

REPO="$(cd "$UNISON_SRC" && git rev-parse --show-toplevel)"
FILES=(src/ubase/uarg.ml src/ubase/uarg.mli src/ubase/prefs.ml src/ubase/prefs.mli)

# The four patched files must be clean, so the restore below cannot discard
# unrelated edits to them.
cd "$REPO"
if ! git diff --quiet -- "${FILES[@]}"; then
  echo "refusing to run: one of the patched files already has local changes:"
  git status --porcelain -- "${FILES[@]}"
  exit 2
fi

restore() { cd "$REPO" && git checkout -- "${FILES[@]}" 2>/dev/null || true; }
trap restore EXIT

echo "== applying parser patch =="
git apply "$PATCH"

cd "$UNISON_SRC"
echo "== building engine objects (make -f Makefile.OCaml tui) =="
make Makefile.cfg >/dev/null
make -f Makefile.OCaml tui >/dev/null

cp "$PROTO" prototype3.ml
inc=(-I lwt -I ubase -I system -I system/generic -I lwt/generic -I +unix -I +str)
echo "== compiling + linking the prototype =="
ocamlopt -g "${inc[@]}" -c prototype3.ml
# Same native objects the `unison` tui links (see the tui build's `-o unison`
# line), with main.cmx / linktext.cmx (the UI entry) replaced by prototype3.cmx.
CMX=(unix.cmxa str.cmxa ubase/umarshal.cmx ubase/rx.cmx unicode_tables.cmx unicode.cmx bytearray.cmx \
  system/system_generic.cmx system/generic/system_impl.cmx system.cmx ubase/projectInfo.cmx ubase/myMap.cmx \
  ubase/safelist.cmx ubase/util.cmx ubase/uarg.cmx ubase/prefs.cmx ubase/trace.cmx ubase/proplist.cmx \
  lwt/pqueue.cmx lwt/lwt.cmx lwt/lwt_util.cmx lwt/generic/lwt_unix_impl.cmx lwt/lwt_unix.cmx features.cmx \
  uutil.cmx case.cmx pred.cmx terminal.cmx fileutil.cmx name.cmx path.cmx fspath.cmx fs.cmx fingerprint.cmx \
  abort.cmx osx.cmx fswatch.cmx propsdata.cmx props.cmx fileinfo.cmx os.cmx lock.cmx clroot.cmx common.cmx \
  tree.cmx checksum.cmx transfer.cmx xferhint.cmx remote.cmx external.cmx negotiate.cmx globals.cmx \
  fswatchold.cmx fpcache.cmx update.cmx moves.cmx copy.cmx stasher.cmx files.cmx sortri.cmx recon.cmx \
  transport.cmx strings.cmx uicommon.cmx uitext.cmx test.cmx prototype3.cmx)
COBJ=(osxsupport.o pty.o bytearray_stubs.o hash_compat.o props_xattr.o props_acl.o copy_stubs.o)
ocamlopt -g "${inc[@]}" -o prototype3 "${CMX[@]}" "${COBJ[@]}"

U="$(mktemp -d)"
printf '# session A: no path configured\n' > "$U/A.prf"
printf 'path = Preset\n' > "$U/B.prf"

rc=0
echo "##### match (bool, alias-opposite-default, int, BOOLDEF) + B..F #####"
EXPECT=match         UNISON="$U" ./prototype3 -batch -confirmbigdeletes=false -maxerrors 5 -fastcheck default || rc=1
echo "##### path-custom (the headline) #####"
EXPECT=path-custom   UNISON="$U" ./prototype3 -path Documents || rc=1
echo "##### repeated-list #####"
EXPECT=repeated-list UNISON="$U" ./prototype3 -path A -path B || rc=1
echo "##### whitespace #####"
EXPECT=whitespace    UNISON="$U" ./prototype3 -path '  ws  ' || rc=1
echo "##### invalid #####"
EXPECT=invalid       UNISON="$U" ./prototype3 -maxerrors notanint || rc=1

echo "== cleanup (build artifacts + restore the four patched files) =="
rm -rf "$U"
rm -f prototype3 prototype3.ml prototype3.cmi prototype3.cmx prototype3.o
make clean >/dev/null
# restore() also runs on EXIT; run it now so a clean run reports a clean tree.
restore

echo "== overall: $([ $rc -eq 0 ] && echo PASS || echo FAIL) =="
exit $rc
