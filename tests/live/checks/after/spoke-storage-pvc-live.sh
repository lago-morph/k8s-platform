#!/usr/bin/env bash
# LIVE behavioral check (after tier) — the SPOKE has a default gp3
# StorageClass backed by the EBS CSI driver, and its PersistentVolumeClaims
# are actually BOUND.
#
# This is the end-to-end oracle for kp-2al.4 / OI-2026-06-11-3 and the
# roadmap step-3 exit ("Healthy with a Bound-PVC oracle"). The two composed
# halves are proven separately — the addon by eks-addon-live.sh (AWS API), the
# StorageClass manifest by tests/unit/test_spoke_storage.sh (git) — but only a
# Bound PVC proves they meet: a class whose provisioner nothing implements
# binds nothing, and a driver with no default class is never asked to.
#
# The failure it reproduces, observed on build #6 (k8-platform-services):
#   kubectl get pvc -A -> 3x Pending in `monitoring`, STORAGECLASS column EMPTY
#   kubectl get csidrivers -> efs.csi.aws.com only
#   kubectl get sc -> gp2 (in-tree kubernetes.io/aws-ebs), not default
#
# Emits `covers "platform.storage/bound-pvc"` — an additive synthetic marker
# (the hello-e2e / keycloak-e2e idiom), not a composed-MR kind: no MR maps to
# "a PVC bound", so it must never be mistaken for the Addon kind's coverage.
#
# Drives the real spoke kube API read-only through the shared SSM relay
# (docs/decisions/0008). Under the SCOPED CI verifier role ssm:StartSession is
# denied by design (ADR-0008), so this check SKIPS there and is a sandbox /
# admin-creds oracle — which is why it covers a synthetic marker and not an
# expect-full kind.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only (kubectl get only) — safe in
# `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

MARKER="platform.storage/bound-pvc"
CLUSTER="${LIVE_CLUSTER:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
HELPER="$REPO_ROOT/scripts/sandbox-kubeconfig.sh"

[ -n "$CLUSTER" ] || skip "no LIVE_CLUSTER set (no cluster under test)"

for bin in aws kubectl jq session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (spoke storage check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"
[ -x "$HELPER" ] || skip "helper $HELPER missing/not executable"

# Bounded relay retry — a tunnel flake must NOT read as "no StorageClass"
# (the auto-014 check-gap class; same idiom as spoke-cluster-secret-live.sh).
RELAY_ATTEMPTS="${LIVE_RELAY_ATTEMPTS:-4}"
RELAY_INTERVAL="${LIVE_RELAY_INTERVAL:-15}"
ERR_FILE="$(mktemp)"
SC_JSON=""; relay_ok=0
for attempt in $(seq 1 "$RELAY_ATTEMPTS"); do
  SC_JSON="$("$HELPER" -c "$CLUSTER" -r "$REGION" --exec \
              kubectl get storageclass -o json 2>"$ERR_FILE")"
  if [ -n "$SC_JSON" ] && printf '%s' "$SC_JSON" | jq -e '.items' >/dev/null 2>&1; then
    relay_ok=1; break
  fi
  # The scoped CI role cannot open SSM sessions (ADR-0008) — not an absence.
  if grep -q "ssm:StartSession" "$ERR_FILE"; then
    rm -f "$ERR_FILE"
    skip "caller cannot ssm:StartSession on the relay (scoped CI role) — the relay path is sandbox-scoped by design (ADR-0008)"
  fi
  log "relay attempt $attempt/$RELAY_ATTEMPTS did not return a parseable StorageClass list for $CLUSTER; retry in ${RELAY_INTERVAL}s"
  [ "$attempt" -lt "$RELAY_ATTEMPTS" ] && sleep "$RELAY_INTERVAL"
done
rm -f "$ERR_FILE"

[ "$relay_ok" -eq 1 ] || skip "spoke kube API not reachable after $RELAY_ATTEMPTS relay attempts (tunnel flake — not an absence)"

fail_count=0

# 1. Exactly one default StorageClass, and it is the gp3 EBS-CSI one.
DEFAULTS="$(printf '%s' "$SC_JSON" | jq -r '
  [.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")]
  | .[].metadata.name')"
NDEF="$(printf '%s\n' "$DEFAULTS" | grep -c . || true)"
if [ "${NDEF:-0}" -eq 0 ]; then
  ng "no default StorageClass on $CLUSTER — PVCs without an explicit class are created UNCLASSED and never bind (the OI-2026-06-11-3 symptom)"
  fail_count=$((fail_count + 1))
elif [ "${NDEF:-0}" -gt 1 ]; then
  # Two defaults is undefined behavior: the API server picks arbitrarily.
  ng "$NDEF default StorageClasses on $CLUSTER ($(printf '%s' "$DEFAULTS" | tr '\n' ' ')) — exactly one must be default"
  fail_count=$((fail_count + 1))
else
  PROV="$(printf '%s' "$SC_JSON" | jq -r --arg n "$DEFAULTS" \
           '.items[] | select(.metadata.name==$n) | .provisioner')"
  if [ "$DEFAULTS" = "gp3" ] && [ "$PROV" = "ebs.csi.aws.com" ]; then
    log "default StorageClass = $DEFAULTS (provisioner $PROV)"
  else
    ng "default StorageClass is '$DEFAULTS' (provisioner '$PROV'); want gp3 / ebs.csi.aws.com"
    fail_count=$((fail_count + 1))
  fi
fi

# 2. The driver the class names is actually registered on the cluster.
CSI_JSON="$("$HELPER" -c "$CLUSTER" -r "$REGION" --exec \
             kubectl get csidrivers -o json 2>/dev/null)"
if printf '%s' "$CSI_JSON" | jq -e '.items[]? | select(.metadata.name=="ebs.csi.aws.com")' >/dev/null 2>&1; then
  log "csidriver ebs.csi.aws.com registered"
else
  ng "csidriver ebs.csi.aws.com is NOT registered on $CLUSTER — the aws-ebs-csi-driver addon is missing or not converged"
  fail_count=$((fail_count + 1))
fi

# 3. THE oracle: every PVC on the cluster is Bound, and there is at least one
#    (zero PVCs would make this vacuously green — the disease this suite kills).
PVC_JSON="$("$HELPER" -c "$CLUSTER" -r "$REGION" --exec \
             kubectl get pvc -A -o json 2>/dev/null)"
if ! printf '%s' "$PVC_JSON" | jq -e '.items' >/dev/null 2>&1; then
  ng "could not read PVCs on $CLUSTER"
  exit 1
fi
TOTAL="$(printf '%s' "$PVC_JSON" | jq '.items | length')"
BOUND="$(printf '%s' "$PVC_JSON" | jq '[.items[] | select(.status.phase=="Bound")] | length')"
if [ "${TOTAL:-0}" -lt 1 ]; then
  skip "no PersistentVolumeClaims on $CLUSTER (the observability set that consumes storage is not deployed — nothing to prove)"
fi
if [ "$BOUND" -ne "$TOTAL" ]; then
  ng "$((TOTAL - BOUND))/$TOTAL PVC(s) on $CLUSTER are not Bound:"
  printf '%s' "$PVC_JSON" | jq -r '.items[] | select(.status.phase!="Bound")
    | "    \(.metadata.namespace)/\(.metadata.name) phase=\(.status.phase) class=\(.spec.storageClassName // "<none>")"'
  fail_count=$((fail_count + 1))
fi

[ "$fail_count" -eq 0 ] || exit 1

ok "spoke storage verified on $CLUSTER: default gp3/ebs.csi.aws.com class, driver registered, $BOUND/$TOTAL PVC(s) Bound"
covers "$MARKER"
exit "$LIVE_RC_PASS"
