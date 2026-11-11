#!/bin/zsh
# Builds the disposable fixtures for the 1.0.1 attended run (issue #197) under one
# base directory, with its own UNISON directory, so nothing real is touched.
#
#   ./make-fixtures.sh [BASE]        default BASE: /tmp/unison-attended-1.0.1
#
# Afterwards:  export UNISON=BASE/unison   and launch the RC from that shell.
# Profiles created (all local unless noted):
#   work, other     TC14/TC15/TC16: roots A/B, one change inside A/Documents, one outside
#   flat-many       a flat list of 600 conflicts (larger than the 221-file review fixture)
#   nested-many     a nested tree (5 levels, 16 folders wide at the top), 480 conflicts
#   shared-direct, shared-include   two profiles with identical roots (direct and through an include)
#   unresolved      include of a file that does not exist (archive removal must be withheld)
#   symlinked       a root that is a symlink (archive removal must be withheld)
#   partial-fail    one destination file is immutable, so exactly one row fails to transfer
#   big-transfer    a sustained disposable transfer (default 6 GB; BIG_MB=2000 to shrink)
#   check-fails     ssh root whose servercmd does not exist (Check Remote Command must fail)
#   ssh-local       ssh://127.0.0.1 root with password auth only (credential sheet cases; needs
#                   Remote Login on and your own account; the user types the password)
set -eu
BASE=${1:-/tmp/unison-attended-1.0.1}
export UNISON=$BASE/unison
BIG_MB=${BIG_MB:-6000}
rm -rf "$BASE"; mkdir -p "$UNISON"
prf() { printf '%s\n' "$@" > "$UNISON/$NAME.prf"; }

# --- work / other (TC14-16): a change inside Documents, one outside
for n in work other; do
  mkdir -p $BASE/$n/A/Documents $BASE/$n/A/Other $BASE/$n/B/Documents $BASE/$n/B/Other
  echo base > $BASE/$n/A/Documents/inside.txt; cp $BASE/$n/A/Documents/inside.txt $BASE/$n/B/Documents/
  echo base > $BASE/$n/A/Other/outside.txt;    cp $BASE/$n/A/Other/outside.txt    $BASE/$n/B/Other/
  NAME=$n prf "root = $BASE/$n/A" "root = $BASE/$n/B"
done

# --- conflict lists: flat and nested, both sides different so every file conflicts
mkdir -p $BASE/flat-many/A $BASE/flat-many/B
for i in $(seq 1 600); do echo "a-$i" > $BASE/flat-many/A/f$i.txt; echo "b-$i" > $BASE/flat-many/B/f$i.txt; done
NAME=flat-many prf "root = $BASE/flat-many/A" "root = $BASE/flat-many/B"
for side in A B; do
  for top in $(seq 1 16); do
    for k in $(seq 1 30); do
      d=$BASE/nested-many/$side/top$top/l2/l3/l4/l5
      mkdir -p $d; echo "$side-$top-$k" > $d/f$k.txt
    done
  done
done
NAME=nested-many prf "root = $BASE/nested-many/A" "root = $BASE/nested-many/B"

# --- shared archive ownership: identical roots, direct and through an include
mkdir -p $BASE/shared/A $BASE/shared/B; echo keep > $BASE/shared/A/doomed.txt; cp $BASE/shared/A/doomed.txt $BASE/shared/B/
NAME=shared-direct prf "root = $BASE/shared/A" "root = $BASE/shared/B"
printf '%s\n' "root = $BASE/shared/A" "root = $BASE/shared/B" > $UNISON/shared-roots.inc
NAME=shared-include prf "include shared-roots.inc"
NAME=unresolved prf "include missing.inc"
mkdir -p $BASE/sym/real $BASE/sym/B; ln -s $BASE/sym/real $BASE/sym/linkA
NAME=symlinked prf "root = $BASE/sym/linkA" "root = $BASE/sym/B"

# --- partial failure: A and B hold the same three files; after pre-sync all three are edited in A, and B's copy of `locked` is made immutable
mkdir -p $BASE/partial/A $BASE/partial/B
for f in ok-1 locked ok-2; do echo v1 > $BASE/partial/A/$f.txt; cp $BASE/partial/A/$f.txt $BASE/partial/B/; done
NAME=partial-fail prf "root = $BASE/partial/A" "root = $BASE/partial/B"

# --- sustained transfer
mkdir -p $BASE/big/A $BASE/big/B
dd if=/dev/urandom of=$BASE/big/A/payload.bin bs=1m count=$BIG_MB 2>/dev/null
NAME=big-transfer prf "root = $BASE/big/A" "root = $BASE/big/B"

# --- SSH credential cases
mkdir -p $BASE/ssh/A $BASE/ssh/B; echo x > $BASE/ssh/A/a.txt
NAME=check-fails prf "root = $BASE/ssh/A" "root = ssh://127.0.0.1/$BASE/ssh/B" "servercmd = /nonexistent/unison" \
  "sshargs = -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
NAME=ssh-local prf "root = $BASE/ssh/A" "root = ssh://$USER@127.0.0.1/$BASE/ssh/B" \
  "sshargs = -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

cat <<M
Fixtures ready under $BASE
  export UNISON=$UNISON
Next, with the RC launcher (quote its path), pre-synchronize while replicas are equal:
  for p in work other shared-direct shared-include; do "<RC launcher>" -ui text -batch \$p; done
Then introduce the differences each case needs (see the run sheet). Immutable file for partial-fail:
  after pre-sync, edit A/ok-1.txt, A/locked.txt, A/ok-2.txt and run: chflags uchg $BASE/partial/B/locked.txt
  (undo with: chflags nouchg $BASE/partial/B/locked.txt)
M
