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
# Pins (kp-2al.53): every managed add-on must be RUNNING the version the repo
# pins (terraform/management/variables.tf eks_addon_versions, read via
# eks_addon_pin) — on the spoke: vpc-cni, kube-proxy, coredns and
# aws-ebs-csi-driver; on the hub: vpc-cni, kube-proxy, coredns. A version
# that differs from the pin means the pin did not reach the cluster (or the
# add-on floats), so the build is not running what was tested.
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

# check_pinned_addon <cluster> <addon> — the add-on exists, is ACTIVE and runs
# exactly the pinned version. Prints one line; returns non-zero on a miss.
check_pinned_addon() {
  local cluster="$1" addon="$2" want desc st have
  want="$(eks_addon_pin "$addon")"
  if [ -z "$want" ]; then
    ng "$addon: no pin in terraform/management/variables.tf eks_addon_versions"
    return 1
  fi
  if ! desc="$(aws eks describe-addon --cluster-name "$cluster" \
        --addon-name "$addon" --region "$REGION" --output json 2>&1)"; then
    ng "$addon on $cluster: describe-addon failed (${desc%%$'\n'*}) — not a managed add-on, so its version floats"
    return 1
  fi
  st="$(printf '%s' "$desc" | jq -r '.addon.status // "unknown"')"
  have="$(printf '%s' "$desc" | jq -r '.addon.addonVersion // "unknown"')"
  if [ "$have" != "$want" ]; then
    ng "$addon on $cluster runs $have, pin is $want"
    return 1
  fi
  if [ "$st" != "ACTIVE" ]; then
    ng "$addon on $cluster is status=$st (want ACTIVE), version $have = pin"
    return 1
  fi
  log "$addon on $cluster: ACTIVE, version $have = pin"
}

pin_fail=0
for a in vpc-cni kube-proxy coredns; do
  check_pinned_addon "$crossplane_cluster" "$a" || pin_fail=$((pin_fail + 1))
done
HUB="$(live_hub_cluster)"
if aws eks describe-cluster --name "$HUB" --region "$REGION" >/dev/null 2>&1; then
  for a in vpc-cni kube-proxy coredns; do
    check_pinned_addon "$HUB" "$a" || pin_fail=$((pin_fail + 1))
  done
else
  log "hub cluster $HUB not describable here — hub add-on pins not checked"
fi
[ "$pin_fail" -eq 0 ] || exit 1

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

PIN="$(eks_addon_pin "$ADDON_NAME")"
if [ "$VERSION" != "$PIN" ]; then
  ng "$ADDON_NAME on $crossplane_cluster runs $VERSION, pin is ${PIN:-<none>}"
  fail_count=$((fail_count + 1))
fi

[ "$fail_count" -eq 0 ] || exit 1

ok "$ADDON_NAME addon ACTIVE on $crossplane_cluster (version $VERSION = pin) under IRSA role $SA_ROLE; core add-ons on pin"
covers "$KIND"
exit "$LIVE_RC_PASS"
