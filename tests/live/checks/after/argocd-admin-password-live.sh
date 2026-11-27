#!/usr/bin/env bash
# live-identity: cluster   (needs secretsmanager:GetSecretValue on k8-platform/management/argocd-admin; the scoped verifier role may read only live-verify/* values)
# LIVE behavioral check (after tier) — the Argo CD admin password stored in AWS
# Secrets Manager actually logs in to the hub's Argo CD (kp-2al.52).
#
# The claim this attests: ASM secret k8-platform/management/argocd-admin is the
# AUTHORITATIVE Argo CD admin password (kp-2al.44; scripts/k8p-argocd-password.sh,
# terraform/management/argocd-credentials.tf). If ASM and Argo CD drift apart,
# the documented way to get the password hands the operator one that does not
# work — and nothing else in the build would notice.
#
# The login is NOT reimplemented here: the check runs
#   scripts/k8p-argocd-password.sh check
# which reads the CURRENT (AWSCURRENT) value and POSTs it to /api/v1/session
# (the endpoint `argocd login` calls) with the JSON body on STDIN — the
# password is never on a command line and is never printed. One login path for
# operators and for the build.
#
# Identity: the CI job's own credentials (`# live-identity: cluster`, the
# live-cluster profile in .github/scripts/live-verify-run.sh). The scoped
# verifier role's GetSecretValue grant is limited to live-verify/* secrets
# (terraform/management/policies/verifier-reaper-policy.json.tftpl), so under
# it this read would be denied. No relay: Argo CD is reached on its public
# endpoint, https://argocd.management.<domain>, discovered from the public
# hosted zone exactly as argocd-endpoint-tls-live.sh does.
#
# Outcomes:
#   PASS  the ASM value logs in as admin
#   FAIL  the hub exists but the secret is missing/unreadable, or the value is
#         refused (or Argo CD never answers — argocd-endpoint-tls-live.sh says
#         which)
#   SKIP  not applicable: tooling/credentials absent, no public hosted zone, no
#         hub cluster
# No COVERS line: a login is not a composed-MR kind, and no expect-full kind
# depends on it.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass, 2=skip, other=fail.
# Read-only (describe + get-secret-value + one session POST) — safe in `full`
# and `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

PW_SCRIPT="$REPO_ROOT/scripts/k8p-argocd-password.sh"
SECRET_ID="k8-platform/management/argocd-admin"
HUB_CLUSTER="${LIVE_HUB_CLUSTER:-k8-platform-mgmt}"
# Login retries (the script's own defaults: 20 x 6 s). Seams keep the unit
# harness instant.
LOGIN_TRIES="${ARGOCD_LOGIN_TRIES:-20}"
LOGIN_SLEEP="${ARGOCD_LOGIN_SLEEP:-6}"

# ── Tooling / credential preconditions — not-applicable (skip) ────────────────
for bin in aws jq curl; do
  command -v "$bin" >/dev/null 2>&1 \
    || skip "$bin not on PATH (Argo CD admin password check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 \
  || skip "no usable AWS credentials in this environment"

# ── Discover the Argo CD URL (never hardcoded — the account/domain rotate) ─────
log "deriving public hosted-zone domain via aws route53 list-hosted-zones"
ZONES_JSON="$(aws route53 list-hosted-zones --output json 2>/dev/null)" \
  || skip "route53:ListHostedZones not permitted / unavailable here"
ZONE_NAME="$(printf '%s' "$ZONES_JSON" | jq -r '
  .HostedZones[] | select(.Config.PrivateZone == false) | .Name' | head -1)"
if [ -z "$ZONE_NAME" ] || [ "$ZONE_NAME" = "null" ]; then
  skip "no public hosted zone found in this account (no Argo CD endpoint to log in to)"
fi
SERVER="https://argocd.management.${ZONE_NAME%.}"
log "Argo CD: $SERVER"

# ── The hub must exist for there to be an Argo CD ─────────────────────────────
ERR="$(aws eks describe-cluster --name "$HUB_CLUSTER" --query cluster.status --output text 2>&1 >/dev/null)"
case "$ERR" in
  "") log "hub cluster $HUB_CLUSTER exists" ;;
  *ResourceNotFoundException*) skip "hub cluster $HUB_CLUSTER not found (management not applied; no Argo CD to log in to)" ;;
  *) ng "cannot describe hub cluster $HUB_CLUSTER: $(printf '%s\n' "$ERR" | grep -m1 . || echo 'no error output')"; exit 1 ;;
esac

# ── The secret must exist: management seeds it ───────────────────────────────
log "ASM secret: $SECRET_ID"
ERR="$(aws secretsmanager describe-secret --secret-id "$SECRET_ID" --query Name --output text 2>&1 >/dev/null)"
case "$ERR" in
  "") : ;;
  *ResourceNotFoundException*)
    ng "ASM secret $SECRET_ID does not exist, but hub $HUB_CLUSTER does."
    ng "  terraform/management/argocd-credentials.tf seeds it; without it there is no"
    ng "  authoritative Argo CD admin password."
    exit 1 ;;
  *)
    ng "cannot read ASM secret $SECRET_ID: $(printf '%s\n' "$ERR" | grep -m1 . || echo 'no error output')"
    exit 1 ;;
esac

# ── The assertion: the CURRENT ASM value logs in ──────────────────────────────
# The script prints only the secret name, its version id and the verdict.
log "logging in as admin with the AWSCURRENT value (via $(basename "$PW_SCRIPT") check)"
ARGOCD_SERVER="$SERVER" ARGOCD_SECRET_ID="$SECRET_ID" \
  LOGIN_TRIES="$LOGIN_TRIES" LOGIN_SLEEP="$LOGIN_SLEEP" NO_COLOR=1 \
  bash "$PW_SCRIPT" check 2>&1 | sed 's/^/    | /'
rc="${PIPESTATUS[0]}"
if [ "$rc" -ne 0 ]; then
  ng "the Argo CD admin password in ASM ($SECRET_ID) does NOT log in to $SERVER (k8p-argocd-password.sh check exit $rc)"
  exit 1
fi
ok "the Argo CD admin password in ASM ($SECRET_ID) logs in to $SERVER as admin"
exit "$LIVE_RC_PASS"
