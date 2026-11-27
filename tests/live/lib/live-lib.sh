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

# ---- relay error handling (kp-zab.6) ----------------------------------------
# Checks drive kubectl through scripts/sandbox-kubeconfig.sh --exec. Its stderr
# must be CAPTURED (never 2>/dev/null): it is the only place the real reason a
# relay call failed appears. Usage inside a retry loop:
#   RELAY_ERR="$(mktemp)"
#   OUT="$("$HELPER" -c "$C" -r "$REGION" --exec kubectl ... 2>"$RELAY_ERR")"
#   <parse OUT; break on success>
#   relay_denied_skip "$RELAY_ERR"        # permission, not a flake: skip now
#   ...after the loop, on failure:
#   relay_err_tail "$RELAY_ERR"           # show WHY before skipping
#
# relay_denied_skip <errfile> — a caller without ssm:StartSession on the relay
# can never succeed, so retrying is wasted time and "tunnel flake" is false.
# Skip immediately with the real reason.
relay_denied_skip() {
  local f="$1"
  [ -s "$f" ] || return 0
  if grep -qE 'ssm:StartSession|not authorized to perform: ssm' "$f"; then
    relay_err_tail "$f"
    rm -f "$f"
    skip "caller cannot ssm:StartSession on the relay (identity lacks relay access) — not a tunnel flake, not an absence"
  fi
}

# relay_err_tail <errfile> — print the last lines the relay helper wrote to
# stderr, or say explicitly that it wrote nothing.
relay_err_tail() {
  local f="$1"
  if [ -s "$f" ]; then
    echo "  relay helper stderr (last 5 lines):"
    grep -v '^[[:space:]]*$' "$f" | tail -5 | sed 's/^/    | /'
  else
    echo "  relay helper stderr: (empty)"
  fi
}

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

# eks_addon_pin <addon-name> — the version the repo pins that EKS add-on to:
# its entry in the default of terraform/management/variables.tf
# eks_addon_versions (the one place each add-on version is set; kp-2al.53).
# Prints nothing if the add-on has no pin. tests/unit/test_eks_addons_pinned.sh
# exercises this same reader.
eks_addon_pin() {
  awk -v a="$1" '
    /^variable "eks_addon_versions"/ { on = 1; next }
    on && /^}/ { exit }
    on && $0 ~ "^[[:space:]]*\"" a "\"[[:space:]]*=" {
      v = $0; sub(/^[^=]*=[[:space:]]*"/, "", v); sub(/".*/, "", v); print v; exit
    }
  ' "$_REPO_ROOT/terraform/management/variables.tf"
}

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
