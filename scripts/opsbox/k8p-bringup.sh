#!/usr/bin/env bash
# k8p-bringup.sh — drive a bring-up from start to green.
#
# What it does for you: waits with the measured budgets, syncs both gates and
# confirms them by their completed operation, watches the stack converge, and
# ends in one red or green.
#
# What it asks YOU to do: click "Run workflow" twice in GitHub Actions. That is
# deliberate — the owner is happy to click buttons; it was the interpreting
# that was error-prone.
#
# Resumable and idempotent. Every stage is checked against the world before it
# is attempted, so re-running after an interruption picks up where it left off
# and re-running when everything is done just prints green.
#
#   k8p-bringup.sh              drive the bring-up
#   k8p-bringup.sh --dry-run    say what it would do, touch nothing
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$HERE/lib.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

WORKFLOW_UI="https://github.com/lago-morph/k8s-platform/actions/workflows/terraform-test.yml"

# Budgets come from measured builds, not from hope. See
# docs/site/how-to/build-the-platform-from-nothing.md.
BUDGET_BASE=900         # 3m21s on build #8; generous headroom for a slow apply
BUDGET_MANAGEMENT=2100  # 20m15s on build #8
BUDGET_SETTLE=900       # transients settled ~8 min after management on build #8
BUDGET_GATE1=2400       # 13m48s-24min across builds; 35 min is the panic line
BUDGET_GATE2=900        # 5m22s on build #8
BUDGET_CONVERGE=1200    # converged ~4 min after gate 2 on build #8
BUDGET_ENDPOINT=600     # DNS and the load balancer settle after the spoke is up

fail() { printf '\n'; red "$1"; printf '\n%s  STOPPED%s  Fix the above, then re-run this script.\n\n' "$C_BOLD$C_RED" "$C_OFF"; exit 1; }

head_ "K8-PLATFORM BRING-UP  $(date -u +%FT%TZ)"
[ "$DRY_RUN" -eq 1 ] && info "DRY RUN — nothing will be changed"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
check_credentials || fail "No AWS identity. This script is meant to run on the ops box, which carries an instance profile."
acct="$(account_id)"
green "credentials — account $acct"

check_zone || fail "No public Route53 hosted zone in this account. The build discovers the domain from it and cannot proceed without one."
dom="$(platform_domain)"
green "domain — $dom"

# ---------------------------------------------------------------------------
# Stage 1 — base
# ---------------------------------------------------------------------------
head_ "Stage 1 of 5 — base"
if check_base; then
  green "base is already applied"
else
  say_do "Open:  $WORKFLOW_UI" \
         "Click: Run workflow" \
         "Set:   phase = base,  action = apply-and-verify" \
         "Branch: main" \
         "" \
         "Then leave this running — it will notice when base is up."
  [ "$DRY_RUN" -eq 1 ] || wait_for check_base "base applied" "$BUDGET_BASE" 20 \
    || fail "base did not come up within the budget. Read the run's log in GitHub Actions."
fi

# ---------------------------------------------------------------------------
# Stage 2 — management
# ---------------------------------------------------------------------------
head_ "Stage 2 of 5 — management"
if check_management; then
  green "management is already applied"
else
  say_do "Open:  $WORKFLOW_UI" \
         "Click: Run workflow" \
         "Set:   phase = management,  action = apply-and-verify" \
         "Branch: main" \
         "" \
         "This one takes about 20 minutes. It is the longest workflow in the build." \
         "" \
         "Note: the run's [management] argocd-url step is continue-on-error, so it" \
         "reports green even when its log says FAIL: HTTP 000. Ignore it — this" \
         "script checks the endpoint itself at the end."
  [ "$DRY_RUN" -eq 1 ] || wait_for check_management "management applied" "$BUDGET_MANAGEMENT" 30 \
    || fail "management did not come up within the budget. Read the run's log in GitHub Actions."
fi

[ "$DRY_RUN" -eq 1 ] || ensure_cluster_access "$HUB_CLUSTER" \
  || fail "Could not reach the hub cluster $HUB_CLUSTER."

# The gates must not be synced before the XRDs and Compositions land, or gate 1
# syncs against a cluster that cannot compose anything.
if ! check_crossplane_resources; then
  info "waiting for crossplane-resources to settle before syncing a gate"
  [ "$DRY_RUN" -eq 1 ] || wait_for check_crossplane_resources "crossplane-resources Synced/Healthy" "$BUDGET_SETTLE" 20 \
    || fail "crossplane-resources never became Synced/Healthy; the gates cannot be synced safely."
fi

# The SHA both gates sync at. Taken from bootstrap's observed target revision,
# which is the right question to ask of that field — "which revision is the
# repo-server serving as main" — even though it is useless as proof that a sync
# happened.
SHA=""
if [ "$DRY_RUN" -eq 0 ]; then
  SHA="$(kc "$HUB_CLUSTER" -n argocd get application bootstrap \
         -o jsonpath='{.status.sync.revision}' 2>/dev/null)"
  case "$SHA" in
    ????????????????????????????????????????) green "gate SHA — $SHA" ;;
    *) fail "Could not read a full commit SHA from bootstrap (got '${SHA}')." ;;
  esac
fi

# ---------------------------------------------------------------------------
# Stage 3 — gate 1
# ---------------------------------------------------------------------------
head_ "Stage 3 of 5 — gate 1, the platform services cluster"
if check_gate1; then
  green "gate 1 is already complete"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would sync platform-cluster-claim at the bootstrap SHA and wait for the four facts"
  else
    if gate_synced_at platform-cluster-claim "$SHA"; then
      green "platform-cluster-claim already synced at $SHA"
    else
      info "syncing platform-cluster-claim at $SHA"
      kc "$HUB_CLUSTER" -n argocd patch application platform-cluster-claim --type merge \
        -p "{\"operation\":{\"sync\":{\"revision\":\"$SHA\"}}}" >/dev/null \
        || fail "Could not patch platform-cluster-claim."
      sleep 20
      gate_synced_at platform-cluster-claim "$SHA" \
        || fail "platform-cluster-claim did not report a completed sync operation at $SHA."
      green "platform-cluster-claim sync operation Succeeded at $SHA"
    fi
    info "this provisions a real EKS cluster; 14-25 minutes is normal"
    wait_for check_gate1 "gate 1 complete (four facts + node group Ready)" "$BUDGET_GATE1" 30 \
      || fail "Gate 1 did not complete. Trace it: scripts/crossplane-trace.sh xplatformcluster/platform -n platform --watch"
  fi
fi

# ---------------------------------------------------------------------------
# Stage 4 — gate 2
# ---------------------------------------------------------------------------
head_ "Stage 4 of 5 — gate 2, register the spoke"
if check_gate2; then
  green "gate 2 is already complete"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would sync spoke-access at the bootstrap SHA and wait for XSpokeAccess Ready"
  else
    if gate_synced_at spoke-access "$SHA"; then
      green "spoke-access already synced at $SHA"
    else
      info "syncing spoke-access at $SHA"
      kc "$HUB_CLUSTER" -n argocd patch application spoke-access --type merge \
        -p "{\"operation\":{\"sync\":{\"revision\":\"$SHA\"}}}" >/dev/null \
        || fail "Could not patch spoke-access."
      sleep 20
      gate_synced_at spoke-access "$SHA" \
        || fail "spoke-access did not report a completed sync operation at $SHA."
      green "spoke-access sync operation Succeeded at $SHA"
    fi
    wait_for check_gate2 "gate 2 complete (XSpokeAccess Ready)" "$BUDGET_GATE2" 20 \
      || fail "Gate 2 did not complete. Trace it: scripts/crossplane-trace.sh xspokeaccess/platform -n platform --watch"
  fi
fi

# ---------------------------------------------------------------------------
# Stage 5 — converge and verify
# ---------------------------------------------------------------------------
head_ "Stage 5 of 5 — converge and verify"
if [ "$DRY_RUN" -eq 1 ]; then
  info "would wait for the Application stack to converge, then check the hello endpoint"
else
  wait_for check_converged "stack converged" "$BUDGET_CONVERGE" 30 \
    || fail "The Application stack did not converge. Look at: kubectl -n argocd get applications"

  wait_for check_endpoint "hello endpoint returns 200" "$BUDGET_ENDPOINT" 20 \
    || fail "The behavioural gate did not come up. DNS and the load balancer can lag the spoke by a few minutes."

  body="$(curl -sL --max-time 25 "https://hello.platform.${dom}/" 2>/dev/null | head -1)"
  info "body: ${body}"
fi

printf '\n%s  BRING-UP COMPLETE%s\n\n' "$C_BOLD$C_GREEN" "$C_OFF"
info "Full status any time:      k8p-status.sh"
info "The platform's own oracle: see docs/site/how-to/build-the-platform-from-nothing.md"
printf '\n'
