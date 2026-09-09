#!/usr/bin/env bash
# LIVE behavioral check (after tier) — the Crossplane-provisioned
# aws-ebs-csi-driver EKS Addon exists, is ACTIVE, and runs under IRSA.
#
# This is the BEHAVIORAL oracle for eks.aws.m.upbound.io/Addon per ADR-0006.
# A static lint that the Composition CONTAINS an Addon base is not evidence;
# this asks EKS. Selection follows the AccessPolicyAssociation check's idiom:
# find the crossplane-stamped EKS cluster (tag
# crossplane-kind=cluster.eks.aws.m.upbound.io — the hub is Terraform-made and
# carries no such tag), then describe the addon on it.
#
# The IRSA assertion is the load-bearing half. An addon installed WITHOUT
# serviceAccountRoleArn comes up ACTIVE and then fails every CreateVolume with
# AccessDenied — i.e. PVCs Pending exactly as in OI-2026-06-11-3, but with a
# healthy-looking addon. Both are checked.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only (describe/list only) — safe
# in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="eks.aws.m.upbound.io/Addon"
ADDON_NAME="aws-ebs-csi-driver"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions — not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (EKS Addon live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for the Crossplane PlatformCluster EKS cluster (region $REGION)"

CLUSTERS_JSON="$(aws eks list-clusters --region "$REGION" \
  --query 'clusters' --output json 2>/dev/null)" \
  || skip "eks:ListClusters not permitted / unavailable here"

COUNT="$(printf '%s' "$CLUSTERS_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no EKS clusters in the account (PlatformCluster path not provisioned)"

crossplane_cluster=""
while IFS= read -r cluster_name; do
  [ -z "$cluster_name" ] && continue
  cluster_arn="$(aws eks describe-cluster --name "$cluster_name" --region "$REGION" \
    --query 'cluster.arn' --output text 2>/dev/null)" || continue
  tags_json="$(aws eks list-tags-for-resource \
    --resource-arn "$cluster_arn" \
    --region "$REGION" --output json 2>/dev/null)" || continue
  is_crossplane="$(printf '%s' "$tags_json" | jq -r '
    .tags as $t
    | if ($t["crossplane-kind"] == "cluster.eks.aws.m.upbound.io") then "yes" else "no" end')"
  if [ "$is_crossplane" = "yes" ]; then
    crossplane_cluster="$cluster_name"
    break
  fi
done <<EOF
$(printf '%s' "$CLUSTERS_JSON" | jq -r '.[]')
EOF

if [ -z "$crossplane_cluster" ]; then
  skip "no EKS cluster tagged crossplane-kind=cluster.eks.aws.m.upbound.io (PlatformCluster abstraction not provisioned)"
fi

log "found crossplane EKS cluster: $crossplane_cluster — listing its addons"

# Distinguish a DENIED read from a genuine absence (the 28759141867 class):
# a denied list must never be reported as "the addon is not provisioned".
if ! ADDONS_JSON="$(aws eks list-addons --cluster-name "$crossplane_cluster" \
      --region "$REGION" --output json 2>&1)"; then
  skip "eks:ListAddons failed on $crossplane_cluster (${ADDONS_JSON%%$'\n'*}) — cannot tell whether the addon exists; fix the caller's permissions"
fi

HAS="$(printf '%s' "$ADDONS_JSON" | jq -r --arg a "$ADDON_NAME" \
        '[.addons[]? | select(. == $a)] | length')"
if [ "${HAS:-0}" -lt 1 ]; then
  skip "no $ADDON_NAME addon on $crossplane_cluster (spoke-storage path not provisioned)"
fi

if ! DESC_JSON="$(aws eks describe-addon --cluster-name "$crossplane_cluster" \
      --addon-name "$ADDON_NAME" --region "$REGION" --output json 2>&1)"; then
  skip "eks:DescribeAddon failed on $crossplane_cluster (${DESC_JSON%%$'\n'*}) — fix the caller's permissions"
fi

STATUS="$(printf '%s' "$DESC_JSON" | jq -r '.addon.status // "unknown"')"
SA_ROLE="$(printf '%s' "$DESC_JSON" | jq -r '.addon.serviceAccountRoleArn // ""')"
VERSION="$(printf '%s' "$DESC_JSON" | jq -r '.addon.addonVersion // "unknown"')"

fail_count=0
if [ "$STATUS" != "ACTIVE" ]; then
  ng "$ADDON_NAME on $crossplane_cluster is status=$STATUS (want ACTIVE)"
  fail_count=$((fail_count + 1))
fi
# IRSA, not the node role: without it the driver AccessDenies on CreateVolume
# and the PVCs stay Pending (OI-2026-06-11-3).
case "$SA_ROLE" in
  arn:aws:iam::*:role/k8-platform-*-ebs-csi)
    log "serviceAccountRoleArn = $SA_ROLE" ;;
  "")
    ng "$ADDON_NAME has NO serviceAccountRoleArn — the driver runs on the node role and will AccessDeny on CreateVolume"
    fail_count=$((fail_count + 1)) ;;
  *)
    ng "$ADDON_NAME serviceAccountRoleArn '$SA_ROLE' is not the composed k8-platform-<cluster>-ebs-csi role"
    fail_count=$((fail_count + 1)) ;;
esac

[ "$fail_count" -eq 0 ] || exit 1

ok "$ADDON_NAME addon ACTIVE on $crossplane_cluster (version $VERSION) under IRSA role $SA_ROLE"
covers "$KIND"
exit "$LIVE_RC_PASS"
