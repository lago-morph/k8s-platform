#!/usr/bin/env bash
# kp-du3: `scripts/beads-sync.sh bootstrap` seeds a throwaway bare mirror that
# bd/dolt then clones. A Claude Code web sandbox clones this repository
# SHALLOW, and git refuses to push shallow history ("shallow update not
# allowed"), so the seeding step used to die and every fresh session started
# with no beads database — which the prepush guard turns into "no git push
# works at all".
#
# The bug class is "a bootstrap step that only works in a full clone", so the
# test builds a real shallow clone and asserts the mirror comes out usable.
# Offline: local file:// remotes only, no bd, no network.
set -uo pipefail
cd "$(dirname "$0")/../.."
. "$(dirname "$0")/lib/test-helpers.sh"

REPO_ROOT=$(pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git_q() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

# ---- a fake origin: several commits on main plus a beads-dolt-data branch ---
ORIGIN="$WORK/origin"
git_q init -q "$ORIGIN"
(
  cd "$ORIGIN" || exit 1
  for i in 1 2 3 4 5; do
    echo "$i" > "file$i.txt"
    git_q add -A
    git_q commit -q -m "commit $i"
  done
  # The Dolt data lives on an unrelated-history branch, as it does on origin.
  git_q checkout -q --orphan beads-dolt-data
  git_q rm -rq --cached . 2>/dev/null
  rm -f file*.txt
  mkdir -p chunks
  echo "pretend dolt chunk" > chunks/data
  git_q add -A
  git_q commit -q -m "dolt data"
  git_q checkout -q main
)

# ---- a SHALLOW clone of it, exactly like the sandbox gets ------------------
CLONE="$WORK/clone"
git_q clone -q --depth 1 "file://$ORIGIN" "$CLONE" 2>/dev/null

if [ "$(git -C "$CLONE" rev-parse --is-shallow-repository)" = "true" ]; then
  pass "harness: the test clone is shallow (the condition the bug needs)"
else
  fail "harness: the test clone is shallow (the condition the bug needs)" \
       "git clone --depth 1 did not produce a shallow repository"
fi

# ---- seed the mirror from that shallow clone -------------------------------
MIRROR="$WORK/mirror.git"
SEED_LOG="$WORK/seed.log"
(
  cd "$CLONE" || exit 1
  git fetch -q origin '+refs/heads/beads-dolt-data:refs/beads-sync/data' || exit 1
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/beads-sync.sh"
  seed_mirror "$MIRROR"
) >"$SEED_LOG" 2>&1
SEED_RC=$?

if [ "$SEED_RC" -eq 0 ]; then
  pass "seed_mirror succeeds from a shallow clone"
else
  fail "seed_mirror succeeds from a shallow clone" \
       "rc=$SEED_RC log: $(tr '\n' ' ' < "$SEED_LOG")"
fi

# ---- and the mirror is what dolt needs: data ref + a branch + HEAD ---------
DATA_SHA=$(git --git-dir="$MIRROR" rev-parse refs/dolt/data 2>/dev/null)
WANT_SHA=$(git -C "$CLONE" rev-parse refs/beads-sync/data 2>/dev/null)
if [ -n "$DATA_SHA" ] && [ "$DATA_SHA" = "$WANT_SHA" ]; then
  pass "mirror carries the Dolt data on refs/dolt/data"
else
  fail "mirror carries the Dolt data on refs/dolt/data" "got='$DATA_SHA' want='$WANT_SHA'"
fi

BRANCHES=$(git --git-dir="$MIRROR" for-each-ref --format='%(refname)' refs/heads 2>/dev/null)
if [ -n "$BRANCHES" ]; then
  pass "mirror has at least one branch (dolt reads a branchless repo as empty)"
else
  fail "mirror has at least one branch (dolt reads a branchless repo as empty)" \
       "refs/heads is empty"
fi

HEAD_REF=$(git --git-dir="$MIRROR" symbolic-ref HEAD 2>/dev/null)
if [ -n "$HEAD_REF" ] && git --git-dir="$MIRROR" rev-parse --verify -q "$HEAD_REF" >/dev/null; then
  pass "mirror HEAD resolves to a real commit"
else
  fail "mirror HEAD resolves to a real commit" "HEAD=$HEAD_REF"
fi

# ---- and the fix stays the fix --------------------------------------------
# Pushing HEAD is the exact operation git rejects out of a shallow clone.
if grep -qE 'git +push +[^|]*"\$mirror" +HEAD:' "$REPO_ROOT/scripts/beads-sync.sh"; then
  fail "seed_mirror never pushes HEAD into the mirror" \
       "a 'git push \$mirror HEAD:...' is back in scripts/beads-sync.sh"
else
  pass "seed_mirror never pushes HEAD into the mirror"
fi

summary
