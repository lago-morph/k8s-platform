#!/usr/bin/env bash
# Shared helpers for the LIVE behavioral suite (FINAL-PLAN §2, §4.4).
#
# The live suite REUSES the integration lib (no fork — DevX-r2 m4): the only
# difference from tests/integration is the orchestrator's tabulation, which
# INVERTS the skip semantics (all-skipped => RED, expect-full skip => FAIL).
# This file sources the integration lib and layers the exit-code contract and
# classification helpers on top.

set -uo pipefail

_LIVE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_LIVE_LIB_DIR/../../.." && pwd)"

# Reuse the integration lib (log/ok/ng/skip/wait_for/require_*/cleanup).
# shellcheck source=/dev/null
. "$_REPO_ROOT/tests/integration/lib/test-lib.sh"

# ---- the exit-code contract (FINAL-PLAN §4.4, k8s-expert m6) --------------
# A child check exits:
#   0  = pass
#   2  = allowed skip (not-applicable OR phase-not-applied — git does not
#        declare this kind for this cluster)
#   3  = expect-full VIOLATION (git declares the kind but it is absent) — a
#        distinct reserved code so the orchestrator NEVER swallows a promoted
#        FAIL as a skip
#   *  = any other non-zero = FAIL
LIVE_RC_PASS=0
LIVE_RC_SKIP=2
LIVE_RC_EXPECT_FULL=3
export LIVE_RC_PASS LIVE_RC_SKIP LIVE_RC_EXPECT_FULL

# Override the integration lib's skip() — which exits 0 and would be counted as
# a silent PASS, the exact disease this overhaul kills. In the live suite a skip
# is the allowed-skip code (2); the orchestrator promotes it to FAIL if the kind
# is expect-full.
skip() { echo "  SKIP: $*"; exit "$LIVE_RC_SKIP"; }

# A check declares which composed-MR kind(s) it verifies by printing, on its
# own stdout, one line per kind:
#     COVERS <group>/<Kind>
# The orchestrator scrapes these to decide whether every expect-full kind was
# actually verified by a PASSING check.
covers() { echo "COVERS $1"; }

# ---- hub vs cluster-under-test (kp-ug3) -----------------------------------
# LIVE_CLUSTER names the ONE cluster under test, which is routinely a SPOKE.
# Some checks assert HUB-side fixtures (the `argocd` + `crossplane-system`
# namespaces and the objects in them) — those must address the HUB regardless of
# which cluster is under test, or they skip structurally and can never pass
# (build6-2042: three negatives skipped with "argocd namespace not present" /
# "crossplane-system namespace not present" while both namespaces existed, on
# the hub).
#
# live_hub_cluster — the hub cluster name. LIVE_HUB_CLUSTER overrides; the
# default is the durable hub name (the same constant hello-e2e-live.sh pins).
live_hub_cluster() { echo "${LIVE_HUB_CLUSTER:-k8-platform-mgmt}"; }

# hub_fixture_absent <what> — a hub-fixture check whose hub API call SUCCEEDED
# but found <what> missing. The hub ANSWERED, so this is a STRUCTURAL absence,
# never a not-applicable: the check still exits with the skip code (only the
# orchestrator knows the active profile), but it prints the marker line the
# orchestrator promotes to a FAIL. A structural skip must not be able to hide.
hub_fixture_absent() {
  echo "HUB-FIXTURE-ABSENT $*"
  skip "$* (hub $(live_hub_cluster) answered — structural absence, promoted to FAIL by the orchestrator)"
}

# expect_full_fail <kind> — a check that found git declares <kind> but the real
# resource is absent calls this and exits LIVE_RC_EXPECT_FULL.
expect_full_fail() {
  echo "  EXPECT-FULL-VIOLATION: git declares $1 for this cluster but the real resource is absent"
  exit "$LIVE_RC_EXPECT_FULL"
}

# live_mode / live_profile accessors with the fail-closed defaults baked in.
# LIVE_MODE unset => readonly (FINAL-PLAN §4.1, round-3 security M2): an
# under-specified invocation degrades to safe, never to provisioning.
live_mode() {
  local m="${LIVE_MODE:-readonly}"
  case "$m" in
    mutating|readonly) echo "$m" ;;
    *) echo "readonly" ;;   # fail-closed on any unknown value
  esac
}
