#!/usr/bin/env bash
# LIVE behavioral suite orchestrator (FINAL-PLAN §4.1/§4.2/§4.4).
#
# This is the inverted-skip orchestrator: where tests/integration/run.sh exits 0
# whenever FAIL==0 (so an all-skipped run on a rotated/empty account reads GREEN
# — the exact disease this overhaul kills), tests/live/run.sh treats
# ALL-SKIPPED ⇒ RED, per profile, and promotes a SKIP of a git-declared
# (expect-full) kind to a FAIL.
#
# Usage:
#   tests/live/run.sh [LIVE_MODE]
#     LIVE_MODE = mutating | readonly   (arg overrides env; unset => readonly)
#
# Environment:
#   LIVE_PROFILE   full (DEFAULT) | verify-only | off     (which TIERS run)
#   LIVE_MODE      mutating | readonly                    (read-only vs mutating
#                  within the live tiers; unset => readonly, fail-closed)
#   LIVE_CLUSTER   cluster-under-test name (for expect-full derivation + evidence)
#   LIVE_EXPECT_FULL   (test seam) space-separated kinds; overrides git derivation
#   LIVE_CHECKS_ROOT   (test seam) dir holding after/ instantiate/ negative/
#                                  (default tests/live/checks)
#   LIVE_SKIP_REGISTER (test seam) path to the register (default tests/live/SKIP_REGISTER.yaml)
#   LIVE_STRICT_SKIPS  1 => a SKIP of a check with no valid register entry
#                      (skips[].check == "<tier>/<name>.sh", reason/owner/expires,
#                      not expired) is a FAIL. CI sets it: the producer is the
#                      build's verdict and must not read green over checks it
#                      never ran (kp-2al.37). Default 0 for local/partial runs.
#   LIVE_CLUSTER_AWS_PROFILE  AWS profile for checks whose header declares
#                      `# live-identity: cluster` (they need ssm:StartSession on
#                      the relay and Kubernetes access). Those checks run with
#                      AWS_PROFILE set and the caller's env creds removed; every
#                      other check keeps the caller's (in CI: scoped) creds.
#   LIVE_SHARED_TUNNELS  space-separated clusters to open ONE relay tunnel each
#                      for, before any check, under the cluster identity; checks'
#                      `--exec` calls then reuse them (and never tear them down),
#                      which is what makes parallel checks safe. Stopped at exit.
#                      A tunnel that will not open is a FAIL.
#   LIVE_TUNNEL_HELPER (test seam) relay helper (default scripts/sandbox-kubeconfig.sh)
#   LIVE_PARALLEL      max checks run at once (default 1 = serial). Output is
#                      buffered per check and printed in sorted order; the tally
#                      is identical to a serial run.
#
# Exit codes (orchestrator):
#   0  clean pass
#   1  FAIL (a check failed, or ALL-SKIPPED/empty under the active profile)
#   3  expect-full violation (a git-declared kind was not verified by a pass)
#   2  reserved for "no kube-API at all" not-applicable abort is NOT used here —
#      a precondition abort is a FAIL (fail-closed), see below.

set -uo pipefail

LIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIVE_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$LIVE_DIR/lib/live-lib.sh"

# ---- config + fail-closed defaults ---------------------------------------

# DEFAULT PROFILE == full is a TESTED INVARIANT (FINAL-PLAN §4.2). This literal
# is the single committed source the unit test reads; changing it is a red diff.
LIVE_PROFILE_DEFAULT=full

LIVE_PROFILE="${LIVE_PROFILE:-$LIVE_PROFILE_DEFAULT}"
# LIVE_MODE: arg #1 overrides env; unset => readonly (fail-closed).
[ "${1:-}" != "" ] && LIVE_MODE="$1"
MODE="$(live_mode)"

CHECKS_ROOT="${LIVE_CHECKS_ROOT:-$LIVE_DIR/checks}"
REGISTER="${LIVE_SKIP_REGISTER:-$LIVE_DIR/SKIP_REGISTER.yaml}"

banner() { echo "════════ live-suite: $* ════════"; }

# ---- helpers (defined before use) ----------------------------------------

# register_has_valid_disable_all <register> — true iff a disable_all entry with
# non-empty reason/owner/expires that is NOT past today exists.
register_has_valid_disable_all() {
  local reg="$1"
  [ -f "$reg" ] || return 1
  local reason owner expires
  reason="$(yq -r '.disable_all.reason // ""' "$reg" 2>/dev/null)"
  owner="$(yq -r '.disable_all.owner // ""' "$reg" 2>/dev/null)"
  expires="$(yq -r '.disable_all.expires // ""' "$reg" 2>/dev/null)"
  [ -n "$reason" ] && [ -n "$owner" ] && [ -n "$expires" ] || return 1
  local today; today="$(date -u +%Y-%m-%d)"
  [ "$expires" \> "$today" ] || [ "$expires" = "$today" ]   # not expired
}

# register_allows_skip <tier/name.sh> — true iff skips[] holds an entry for
# exactly that check with non-empty reason/owner/expires, not expired.
register_allows_skip() {
  local id="$1" reg="$REGISTER"
  [ -f "$reg" ] || return 1
  local n
  n="$(ID="$id" TODAY="$(date -u +%Y-%m-%d)" yq -r '
        [ .skips[]? | select(.check == strenv(ID))
          | select((.reason // "") != "" and (.owner // "") != "" and (.expires // "") != "")
          | select((.expires | tostring) >= strenv(TODAY)) ] | length' "$reg" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
}

# check_id <script> — "<tier>/<name>.sh", the register's key for a check.
check_id() { echo "$(basename "$(dirname "$1")")/$(basename "$1")"; }

# check_identity <script> — the identity a check declares in its header
# (`# live-identity: cluster`), or "default".
check_identity() {
  local v
  v="$(grep -m1 -E '^# live-identity:' "$1" 2>/dev/null | awk '{print $3}')"
  echo "${v:-default}"
}

# as_cluster_identity <cmd...> — run a command under LIVE_CLUSTER_AWS_PROFILE
# with the caller's env creds removed (env vars outrank AWS_PROFILE).
as_cluster_identity() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    AWS_PROFILE="$LIVE_CLUSTER_AWS_PROFILE" "$@"
}

# derive_expect_full — the git-declared composed-MR kinds for the cluster under
# test (FINAL-PLAN §4.3: derived from GIT, never from the system under test).
# LIVE_EXPECT_FULL overrides for the unit harness.
derive_expect_full() {
  if [ -n "${LIVE_EXPECT_FULL+x}" ]; then
    printf '%s\n' $LIVE_EXPECT_FULL | sed '/^$/d' | sort -u
    return
  fi
  # The kind set comes from the committed Compositions (the coverage deriver);
  # whether a given cluster declares them is refined per-cluster in P2 (the
  # git-cluster-declaration parse). Until then, fail-closed: with no checks
  # populated the all-skip⇒RED rule already prevents a green-by-absence.
  # --expect-full (not the bare print) is the EXPECT-FULL set: the derived kinds
  # MINUS the kinds tests/coverage/registry.yaml records as transitively
  # defended (`coverage: transitive`). Those have no standalone check and emit
  # no COVERS line of their own — a coupled check's assertions prove them — so
  # counting them here reported them unverified forever (kp-2al.20).
  local deriver="$REPO_ROOT/tests/coverage/derive-coverage.sh"
  [ -x "$deriver" ] && "$deriver" --expect-full 2>/dev/null | sort -u || true
}

# ---- profile validation + the verify-only ⇒ readonly coupling ------------
# (FINAL-PLAN §4.2) The PROFILE chooses WHICH TIERS run; LIVE_MODE chooses
# read-only vs mutating WITHIN them. verify-only has no instantiate tier to
# mutate, so verify-only IMPLIES readonly, and verify-only+mutating is rejected.
case "$LIVE_PROFILE" in
  full) ;;
  verify-only)
    if [ "$MODE" = "mutating" ]; then
      echo "FAIL: LIVE_PROFILE=verify-only is incompatible with LIVE_MODE=mutating" >&2
      echo "      (verify-only drops the instantiate tier; there is nothing to mutate)." >&2
      exit 1
    fi
    MODE=readonly   # verify-only implies readonly
    ;;
  off)
    # off is RED-and-non-zero UNLESS a top-level disable_all register entry
    # (reason/owner/expires) exists. off/disable_all is a thin alias that writes
    # a SKIP_REGISTER-shaped entry — one durable disable path (round-3 devx M2).
    if register_has_valid_disable_all "$REGISTER"; then
      banner "PROFILE=off — DISABLED via an audited disable_all register entry"
      echo "  (this is a recorded, attributable choice; not a silent skip)"
      exit 0
    fi
    echo "FAIL: LIVE_PROFILE=off requires a valid top-level disable_all entry" >&2
    echo "      (reason/owner/expires, not expired) in $REGISTER. RED by design." >&2
    exit 1
    ;;
  *)
    echo "FAIL: unknown LIVE_PROFILE='$LIVE_PROFILE' (full|verify-only|off)" >&2
    exit 1
    ;;
esac

# ---- tier → profile map (FINAL-PLAN §4.2) --------------------------------
#   after        (read-only existence/convergence/health) runs in full + verify-only
#   instantiate  (cheap-hermetic create-and-verify)        runs in full only
#   negative     (guard-fired)                              runs in full only
ACTIVE_TIERS="after"
[ "$LIVE_PROFILE" = "full" ] && ACTIVE_TIERS="after instantiate negative"

# ---- run the active tiers -------------------------------------------------
banner "PROFILE=$LIVE_PROFILE MODE=$MODE TIERS='$ACTIVE_TIERS' CLUSTER='${LIVE_CLUSTER:-?}'"

RUN_ID="${RUN_ID:-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6 || echo $$)}"
export RUN_ID

PASS=0; SKIP=0; FAIL=0; CHILD_EXPECTVIOL=0
COVERED_PASS=""          # group/kinds verified by a PASSING check
declare -a FAILED=()           # hard failures
declare -a EXPECT_FAILED=()    # children that exited LIVE_RC_EXPECT_FULL (code 3)

# P3: renew the account lease. Called before each serial check, and before and
# after the parallel batch (the 30 min lease far outlasts one batch). Losing it
# means another run stole it (ours expired) — stop mutating (fail-closed).
renew_or_die() {
  if [ "${P3_ENGAGED:-0}" = "1" ]; then
    mutex_renew "$RUN_ID" || {
      echo "FAIL: lost the account-mutex lease mid-run (another run stole it); RED by design." >&2
      exit 1
    }
  fi
}

# exec_check <script> <outfile> — run one check under its declared identity;
# its combined output goes to <outfile>, its exit code to <outfile>.rc.
exec_check() {
  local script="$1" outfile="$2" ident rc
  ident="$(check_identity "$script")"
  set +e
  if [ "$ident" = "cluster" ] && [ -n "${LIVE_CLUSTER_AWS_PROFILE:-}" ]; then
    echo "  identity: cluster (AWS_PROFILE=$LIVE_CLUSTER_AWS_PROFILE)" > "$outfile"
    as_cluster_identity LIVE_MODE="$MODE" bash "$script" >> "$outfile" 2>&1
  else
    echo "  identity: $ident (caller's credentials)" > "$outfile"
    LIVE_MODE="$MODE" bash "$script" >> "$outfile" 2>&1
  fi
  rc=$?
  set -e
  echo "$rc" > "$outfile.rc"
}

# tally_check <script> <outfile> — print a finished check's output and count it.
tally_check() {
  local script="$1" outfile="$2" out rc
  out="$(cat "$outfile")"
  rc="$(cat "$outfile.rc")"
  echo ""
  echo "──── $script (RUN_ID=$RUN_ID, MODE=$MODE) ────"
  printf '%s\n' "$out"
  case "$rc" in
    "$LIVE_RC_PASS")
      PASS=$((PASS+1))
      # record covered kinds from this passing check
      local k
      while IFS= read -r k; do
        [ -n "$k" ] && COVERED_PASS="$COVERED_PASS
$k"
      done < <(printf '%s\n' "$out" | sed -n 's/^COVERS //p')
      ;;
    "$LIVE_RC_SKIP")
      # kp-ug3: a HUB-FIXTURE check that skipped because a hub fixture was
      # MISSING while the hub itself answered is a STRUCTURAL skip, not a
      # not-applicable — promote it to a FAIL so it cannot hide. (The marker is
      # printed by hub_fixture_absent() in lib/live-lib.sh; a skip for absent
      # tooling/creds/relay prints no marker and stays a skip.)
      local absent
      absent="$(printf '%s\n' "$out" | sed -n 's/^HUB-FIXTURE-ABSENT //p' | head -1)"
      if [ -n "$absent" ]; then
        FAIL=$((FAIL+1))
        FAILED+=("$script (hub-fixture absent on $(live_hub_cluster): $absent)")
      elif [ "${LIVE_STRICT_SKIPS:-0}" = "1" ] && ! register_allows_skip "$(check_id "$script")"; then
        # kp-2al.37: in strict mode a skip must be a recorded, attributable
        # choice. Anything else is a check the verdict never ran.
        FAIL=$((FAIL+1))
        FAILED+=("$(check_id "$script") (unregistered skip — no valid entry in $REGISTER)")
      else
        SKIP=$((SKIP+1))
      fi
      ;;
    "$LIVE_RC_EXPECT_FULL") CHILD_EXPECTVIOL=$((CHILD_EXPECTVIOL+1)); EXPECT_FAILED+=("$script (expect-full)") ;;
    *)                     FAIL=$((FAIL+1)); FAILED+=("$script (exit=$rc)") ;;
  esac
}

# ---- P3: account-mutex + reaper (engage ONLY for the mutating tiers) -------
# (FINAL-PLAN §8/§14.8) The instantiate + negative tiers MUTATE the shared
# account, so before they run we (a) reap leaked resources from dead prior runs,
# then (b) hold the account lease so two mutating runs — or a run and the reaper —
# never collide. Gated on full+mutating: the after tier is read-only and the
# default readonly mode never provisions, so neither needs the lease. The libs are
# sourced through seams (LIVE_MUTEX_LIB / LIVE_REAPER_LIB) so the orchestrator unit
# test can fake the mutex + reaper and assert the engagement order.
P3_ENGAGED=0
if [ "$LIVE_PROFILE" = "full" ] && [ "$MODE" = "mutating" ]; then
  # shellcheck source=/dev/null
  . "${LIVE_MUTEX_LIB:-$LIVE_DIR/lib/account-mutex.sh}"
  # shellcheck source=/dev/null
  . "${LIVE_REAPER_LIB:-$LIVE_DIR/lib/reaper-run.sh}"

  # Reaper FIRST — clear leaked resources from dead prior runs before we provision.
  # Live deletes in mutating mode (LIVE_REAPER_DRY_RUN=1 forces observe-only).
  banner "P3 reaper sweep — clearing leaked resources from dead runs (run_id=$RUN_ID)"
  REAPER_DRY_RUN="${LIVE_REAPER_DRY_RUN:-0}"   # full+mutating ⇒ live deletes; set 1 to observe
  reaper_run "$RUN_ID" || true

  # Then hold the account lease for the mutating tiers (fail-closed if we cannot).
  if mutex_acquire "$RUN_ID"; then
    P3_ENGAGED=1
    banner "P3 account lease HELD (run_id=$RUN_ID) — mutating tiers may proceed"
  else
    echo "FAIL: could not acquire the account-mutex lease (another run holds it); RED by design." >&2
    echo "      (the mutating tiers must not run two-at-a-time on one account — §8/§14.8)" >&2
    exit 1
  fi
fi

# ---- exit cleanup: release the lease, stop shared tunnels, drop buffers ----
TUNNEL_HELPER="${LIVE_TUNNEL_HELPER:-$REPO_ROOT/scripts/sandbox-kubeconfig.sh}"
OPENED_TUNNELS=""
OUT_DIR="$(mktemp -d)"
on_exit() {
  local c
  for c in $OPENED_TUNNELS; do
    if [ -n "${LIVE_CLUSTER_AWS_PROFILE:-}" ]; then
      as_cluster_identity bash "$TUNNEL_HELPER" -c "$c" --stop >/dev/null 2>&1 || true
    else
      bash "$TUNNEL_HELPER" -c "$c" --stop >/dev/null 2>&1 || true
    fi
  done
  [ "${P3_ENGAGED:-0}" = "1" ] && mutex_release "$RUN_ID"
  rm -rf "$OUT_DIR"
}
trap on_exit EXIT

# ---- shared relay tunnels (kp-2al.37) --------------------------------------
# One tunnel per cluster, opened once under the cluster identity. Every check's
# `sandbox-kubeconfig.sh --exec` then REUSES it and leaves it up, so no check can
# tear down a tunnel another check is using — the collision that made checks
# serial and produced the "tunnel flake" skips. A tunnel that will not open is a
# FAIL: the checks behind it would otherwise skip, which is not a verdict.
for c in ${LIVE_SHARED_TUNNELS:-}; do
  banner "opening shared relay tunnel for $c"
  if [ -n "${LIVE_CLUSTER_AWS_PROFILE:-}" ]; then
    as_cluster_identity bash "$TUNNEL_HELPER" -c "$c" >/dev/null; trc=$?
  else
    bash "$TUNNEL_HELPER" -c "$c" >/dev/null; trc=$?
  fi
  if [ "$trc" -ne 0 ]; then
    echo "FAIL: shared relay tunnel for $c did not open (helper exit $trc); RED by design." >&2
    exit 1
  fi
  OPENED_TUNNELS="$OPENED_TUNNELS $c"
  echo "  tunnel open for $c"
done

# ---- run the checks ----------------------------------------------------------
SCRIPTS=()
for tier in $ACTIVE_TIERS; do
  dir="$CHECKS_ROOT/$tier"
  [ -d "$dir" ] || continue
  while IFS= read -r script; do
    [ -n "$script" ] && SCRIPTS+=("$script")
  done < <(find "$dir" -maxdepth 1 -name '*.sh' 2>/dev/null | sort)
done
CHECK_COUNT=${#SCRIPTS[@]}
PARALLEL="${LIVE_PARALLEL:-1}"
case "$PARALLEL" in ''|*[!0-9]*|0) PARALLEL=1 ;; esac

if [ "$PARALLEL" -le 1 ]; then
  i=0
  for script in "${SCRIPTS[@]}"; do
    i=$((i+1))
    renew_or_die
    exec_check "$script" "$OUT_DIR/$i"
    tally_check "$script" "$OUT_DIR/$i"
  done
else
  banner "running $CHECK_COUNT checks, up to $PARALLEL at a time"
  renew_or_die
  i=0
  for script in "${SCRIPTS[@]}"; do
    i=$((i+1))
    while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do wait -n 2>/dev/null || true; done
    exec_check "$script" "$OUT_DIR/$i" &
  done
  wait
  renew_or_die
  i=0
  for script in "${SCRIPTS[@]}"; do
    i=$((i+1))
    tally_check "$script" "$OUT_DIR/$i"
  done
fi

# ---- expect-full promotion: every git-declared kind must be verified -------
EXPECT_FULL="$(derive_expect_full)"
COVERED_SORTED="$(printf '%s\n' "$COVERED_PASS" | sed '/^$/d' | sort -u)"
MISSING_EXPECT=""
if [ -n "$EXPECT_FULL" ]; then
  MISSING_EXPECT="$(comm -23 <(printf '%s\n' "$EXPECT_FULL") <(printf '%s\n' "$COVERED_SORTED"))"
fi

# kp-lc5: ONE accounting for expect-full violations. A violation is EITHER a
# child that exited LIVE_RC_EXPECT_FULL, OR a git-declared kind that no passing
# check covered — both are counted, both are printed below, and any non-zero
# total is exit 3. Counting only the first is how build6-2220 printed four
# violations under "expect-full-violations=0": the exit code was honest, the
# counter was not, and CI's pass criterion reads the counter.
MISSING_EXPECT_COUNT="$(printf '%s\n' "$MISSING_EXPECT" | grep -c . || true)"
EXPECTVIOL=$(( CHILD_EXPECTVIOL + MISSING_EXPECT_COUNT ))

# ---- tabulate (the inversion) ---------------------------------------------
echo ""
banner "summary  pass=$PASS skip=$SKIP fail=$FAIL expect-full-violations=$EXPECTVIOL checks=$CHECK_COUNT"

RC=0
# expect-full kinds with no passing coverage => promoted FAIL (reserved code 3).
# Every violation the counter counts is also NAMED here, and vice versa.
if [ "$EXPECTVIOL" -gt 0 ]; then
  echo "  EXPECT-FULL VIOLATION ($EXPECTVIOL) — git declares these but no passing check verified them" >&2
  echo "  (each entry is either an unverified kind, or the check that reported one):" >&2
  if [ -n "$MISSING_EXPECT" ]; then
    printf '    - %s\n' $MISSING_EXPECT >&2
  fi
  if [ "${#EXPECT_FAILED[@]}" -gt 0 ]; then
    for t in "${EXPECT_FAILED[@]}"; do echo "    - $t" >&2; done
  fi
  RC=3
fi
# any hard failure
if [ "$FAIL" -gt 0 ]; then
  echo "  FAILED checks:" >&2
  for t in "${FAILED[@]}"; do echo "    - $t" >&2; done
  [ "$RC" -eq 0 ] && RC=1
fi
# ALL-SKIPPED (or zero checks ran) under the active profile => RED. This is the
# per-profile anti-silent-regression floor: the suite cannot read green having
# verified nothing (FINAL-PLAN §4.2/§4.4).
if [ "$PASS" -eq 0 ] && [ "$RC" -eq 0 ]; then
  echo "  ALL-SKIPPED / NO-CHECKS under profile=$LIVE_PROFILE — RED by design." >&2
  echo "    (the live suite must not read green having verified nothing; populate" >&2
  echo "     the '$ACTIVE_TIERS' tier(s) or record an audited disable in $REGISTER)" >&2
  RC=1
fi

[ "$RC" -eq 0 ] && banner "PASS"
exit "$RC"
