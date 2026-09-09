#!/usr/bin/env bash
# Unit tests for SPOKE STORAGE — the EBS CSI driver addon, its IRSA role, and
# the default gp3 StorageClass (bead kp-2al.4 / OI-2026-06-11-3).
#
# The bug this reproduces: a spoke shipped NO CSI driver and NO default
# StorageClass, so every observability PVC (prometheus, alertmanager, loki)
# stayed Pending forever with an EMPTY storageclass column — observed live on
# build #6 (cluster k8-platform-services):
#   * `aws eks list-addons --cluster-name k8-platform-services` => []
#   * `kubectl get csidrivers` => efs.csi.aws.com only (no ebs.csi.aws.com)
#   * `kubectl get sc` => gp2 (in-tree kubernetes.io/aws-ebs), NOT default
#   * `kubectl get pvc -A` => 3x Pending, STORAGECLASS column empty
#   * no k8-platform-k8-platform-services-ebs-csi IAM role
#
# Three things must therefore be true in git, and this file gates all three:
#
#   1. COMPOSITION — the XSpokeAccess Composition composes an EBS-CSI IRSA
#      Role + AWS-managed policy attachment + the managed EKS Addon, wired so
#      the addon's serviceAccountRoleArn is the role it just created. Trust
#      shape follows the external-dns/ESO precedent EXACTLY (StringEquals on
#      BOTH :sub and :aud — auto-008 S2 — never StringLike) with the subject
#      pinned to the addon's own SA kube-system/ebs-csi-controller-sa.
#   2. DELIVERY — the default gp3 StorageClass reaches the spoke by the same
#      route every other cluster-scoped spoke object takes: an ApplicationSet
#      under argocd/apps/spoke/ with an in-repo path source (the ESO
#      ClusterSecretStore precedent), and the platform-spoke AppProject
#      whitelists the CLUSTER-SCOPED kind (the IngressClass precedent — a
#      cluster-scoped kind absent from clusterResourceWhitelist fails closed).
#   3. ORACLE PLUMBING — the new composed MR kind is registered for coverage
#      and the scoped verifier role can actually READ the addon (the
#      28759141867 class: an ungranted read reads as "not provisioned").
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

COMP=crossplane/compositions/xspokeaccess.yaml
XRD=crossplane/xrds/xspokeaccess.yaml
SC=platform-services/storage/spoke/gp3-storageclass.yaml
APPSET=argocd/apps/spoke/storage.yaml
PROJECT=argocd/projects/platform-spoke.yaml
ORACLE=tests/coverage/expected-coverage.txt
REGISTRY=tests/coverage/registry.yaml
VERIFIER=terraform/management/policies/verifier-reaper-policy.json.tftpl

PT='.spec.pipeline[] | select(.functionRef.name == "function-patch-and-transform") | .input'

for f in "$COMP" "$XRD" "$SC" "$APPSET" "$PROJECT" "$ORACLE" "$REGISTRY" "$VERIFIER"; do
  if [ -f "$f" ]; then _pass "file_exists:$f"; else _fail "file_exists:$f" "$f not found"; assert_summary; fi
done

# ---- 1. Composition: EBS CSI IRSA Role ---------------------------------
R='.resources[] | select(.name=="ebs-csi-role")'
assert_eq "ebs_csi_role_kind" "Role" "$(yq -r "${PT}${R} | .base.kind" "$COMP")"
assert_eq "ebs_csi_role_apiVersion" "iam.aws.m.upbound.io/v1beta1" \
  "$(yq -r "${PT}${R} | .base.apiVersion" "$COMP")"

# Role NAME is derived from spec.clusterName, never a literal — and it stays
# inside the k8-platform-* prefix the crossplane provider policy's IAMRoles
# Sid is scoped to (terraform/management/irsa.tf), or CreateRole is denied.
assert_eq "ebs_csi_role_name_fmt" "k8-platform-%s-ebs-csi" \
  "$(yq -r "${PT}${R} | .patches[] | select(.toFieldPath==\"metadata.annotations[crossplane.io/external-name]\") | .transforms[0].string.fmt" "$COMP")"
assert_eq "ebs_csi_role_name_source" "spec.clusterName" \
  "$(yq -r "${PT}${R} | .patches[] | select(.toFieldPath==\"metadata.annotations[crossplane.io/external-name]\") | .fromFieldPath" "$COMP")"

# Trust policy: built from the environment (accountId + oidcHost), Required so
# the Role is never created with an empty/partial trust document.
TRUST="$(yq -r "${PT}${R} | .patches[] | select(.toFieldPath==\"spec.forProvider.assumeRolePolicy\") | .combine.string.fmt" "$COMP")"
assert_eq "ebs_csi_trust_required" "Required" \
  "$(yq -r "${PT}${R} | .patches[] | select(.toFieldPath==\"spec.forProvider.assumeRolePolicy\") | .policy.fromFieldPath" "$COMP")"
echo "$TRUST" | grep -q 'sts:AssumeRoleWithWebIdentity' \
  && _pass "ebs_csi_trust_web_identity" \
  || _fail "ebs_csi_trust_web_identity" "trust policy is not an IRSA AssumeRoleWithWebIdentity document"
echo "$TRUST" | grep -q 'StringEquals' \
  && _pass "ebs_csi_trust_string_equals" \
  || _fail "ebs_csi_trust_string_equals" "trust policy must use StringEquals (auto-008 S2)"
echo "$TRUST" | grep -q 'StringLike' \
  && _fail "ebs_csi_trust_no_string_like" "trust policy uses StringLike — banned (auto-008 S2)" \
  || _pass "ebs_csi_trust_no_string_like"
echo "$TRUST" | grep -q ':sub' && echo "$TRUST" | grep -q ':aud' \
  && _pass "ebs_csi_trust_sub_and_aud" \
  || _fail "ebs_csi_trust_sub_and_aud" "trust policy must pin BOTH :sub and :aud"
# The addon creates its OWN service account; the subject is fixed by AWS.
echo "$TRUST" | grep -q 'system:serviceaccount:kube-system:ebs-csi-controller-sa' \
  && _pass "ebs_csi_trust_subject" \
  || _fail "ebs_csi_trust_subject" "trust subject must be system:serviceaccount:kube-system:ebs-csi-controller-sa"

# The ARN must reach the composite so the Addon below can consume it.
assert_eq "ebs_csi_role_arn_to_composite" "status.ebsCsiRoleArn" \
  "$(yq -r "${PT}${R} | .patches[] | select(.type==\"ToCompositeFieldPath\") | select(.fromFieldPath==\"status.atProvider.arn\") | .toFieldPath" "$COMP")"
assert_eq "xrd_status_ebsCsiRoleArn" "string" \
  "$(yq -r '.spec.versions[0].schema.openAPIV3Schema.properties.status.properties.ebsCsiRoleArn.type' "$XRD")"

# ---- 2. Composition: AWS-managed policy attachment ---------------------
# AmazonEBSCSIDriverPolicy is an AWS-MANAGED policy, so this is a
# RolePolicyAttachment (iam:AttachRolePolicy, granted) — the platform-cluster
# node-*-policy precedent — NOT an inline RolePolicy (which exists in this
# Composition only because external-dns/ESO need CUSTOM documents and
# iam:CreatePolicy is unavailable).
A='.resources[] | select(.name=="ebs-csi-policy-attachment")'
assert_eq "ebs_csi_attachment_kind" "RolePolicyAttachment" "$(yq -r "${PT}${A} | .base.kind" "$COMP")"
assert_eq "ebs_csi_attachment_policy_arn" "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" \
  "$(yq -r "${PT}${A} | .base.spec.forProvider.policyArn" "$COMP")"
assert_eq "ebs_csi_attachment_role_fmt" "k8-platform-%s-ebs-csi" \
  "$(yq -r "${PT}${A} | .patches[] | select(.toFieldPath==\"spec.forProvider.role\") | .transforms[0].string.fmt" "$COMP")"

# ---- 3. Composition: the managed EKS Addon -----------------------------
D='.resources[] | select(.name=="ebs-csi-addon")'
assert_eq "ebs_csi_addon_kind" "Addon" "$(yq -r "${PT}${D} | .base.kind" "$COMP")"
assert_eq "ebs_csi_addon_apiVersion" "eks.aws.m.upbound.io/v1beta1" \
  "$(yq -r "${PT}${D} | .base.apiVersion" "$COMP")"
assert_eq "ebs_csi_addon_name" "aws-ebs-csi-driver" \
  "$(yq -r "${PT}${D} | .base.spec.forProvider.addonName" "$COMP")"
assert_eq "ebs_csi_addon_cluster_source" "spec.clusterName" \
  "$(yq -r "${PT}${D} | .patches[] | select(.toFieldPath==\"spec.forProvider.clusterName\") | .fromFieldPath" "$COMP")"
assert_eq "ebs_csi_addon_region_source" "spec.region" \
  "$(yq -r "${PT}${D} | .patches[] | select(.toFieldPath==\"spec.forProvider.region\") | .fromFieldPath" "$COMP")"
# The addon must run under IRSA, and must not be created before the role ARN
# resolves (Required) — an addon installed without the role gets AccessDenied
# on every CreateVolume and the PVCs stay Pending exactly as before.
assert_eq "ebs_csi_addon_sa_role_source" "status.ebsCsiRoleArn" \
  "$(yq -r "${PT}${D} | .patches[] | select(.toFieldPath==\"spec.forProvider.serviceAccountRoleArn\") | .fromFieldPath" "$COMP")"
assert_eq "ebs_csi_addon_sa_role_required" "Required" \
  "$(yq -r "${PT}${D} | .patches[] | select(.toFieldPath==\"spec.forProvider.serviceAccountRoleArn\") | .policy.fromFieldPath" "$COMP")"

# No account-ephemeral literal may be baked into the new resources (AGENTS
# §8.1): the account id rides the EnvironmentConfig, never the Composition.
if yq -r "${PT}.resources[] | select(.name==\"ebs-csi-role\" or .name==\"ebs-csi-addon\" or .name==\"ebs-csi-policy-attachment\")" "$COMP" \
   | grep -Eq 'arn:aws:iam::[0-9]{12}:'; then
  _fail "ebs_csi_no_hardcoded_account" "a 12-digit account id is committed in the EBS-CSI resources"
else
  _pass "ebs_csi_no_hardcoded_account"
fi

# ---- 4. The default gp3 StorageClass -----------------------------------
assert_eq "sc_kind" "StorageClass" "$(yq -r '.kind' "$SC")"
assert_eq "sc_apiVersion" "storage.k8s.io/v1" "$(yq -r '.apiVersion' "$SC")"
assert_eq "sc_name" "gp3" "$(yq -r '.metadata.name' "$SC")"
# THE fix for the empty-STORAGECLASS PVCs: the chart PVCs set no
# storageClassName, so a cluster DEFAULT class is what binds them.
assert_eq "sc_is_default" "true" \
  "$(yq -r '.metadata.annotations["storageclass.kubernetes.io/is-default-class"]' "$SC")"
assert_eq "sc_provisioner" "ebs.csi.aws.com" "$(yq -r '.provisioner' "$SC")"
assert_eq "sc_type_gp3" "gp3" "$(yq -r '.parameters.type' "$SC")"
# WaitForFirstConsumer: the nodegroup spans AZs, so an Immediate volume can be
# created in an AZ no pod can schedule into (permanent Pending).
assert_eq "sc_binding_mode" "WaitForFirstConsumer" "$(yq -r '.volumeBindingMode' "$SC")"
assert_eq "sc_expansion" "true" "$(yq -r '.allowVolumeExpansion' "$SC")"
assert_eq "sc_reclaim" "Delete" "$(yq -r '.reclaimPolicy' "$SC")"

# ---- 5. Delivery: the ApplicationSet + the AppProject whitelist ---------
assert_eq "appset_kind" "ApplicationSet" "$(yq -r '.kind' "$APPSET")"
assert_eq "appset_name" "storage" "$(yq -r '.metadata.name' "$APPSET")"
PATHS="$(yq -r '[.spec.template.spec.sources[].path] | .[] | select(. != null)' "$APPSET")"
echo "$PATHS" | grep -qx 'platform-services/storage/spoke' \
  && _pass "appset_path_points_at_storageclass_dir" \
  || _fail "appset_path_points_at_storageclass_dir" "no source path platform-services/storage/spoke (got: $PATHS)"
# The class must exist BEFORE the observability charts create their PVCs
# (kube-prometheus-stack + loki are wave 40).
WAVE="$(yq -r '.spec.template.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$APPSET")"
if [ "$WAVE" != "null" ] && [ "$WAVE" -lt 40 ] 2>/dev/null; then
  _pass "appset_wave_before_observability ($WAVE < 40)"
else
  _fail "appset_wave_before_observability" "sync-wave '$WAVE' must be a number < 40 (observability band)"
fi
# StorageClass is CLUSTER-scoped: absent from clusterResourceWhitelist the sync
# fails closed ("not permitted in project platform-spoke") — the IngressClass
# and ClusterSecretStore precedent.
if yq -r '.spec.clusterResourceWhitelist[] | .group + "/" + .kind' "$PROJECT" \
   | grep -qx 'storage.k8s.io/StorageClass'; then
  _pass "appproject_whitelists_storageclass"
else
  _fail "appproject_whitelists_storageclass" "$PROJECT clusterResourceWhitelist missing storage.k8s.io/StorageClass"
fi

# ---- 6. Oracle plumbing ------------------------------------------------
grep -qx 'eks.aws.m.upbound.io/Addon' "$ORACLE" \
  && _pass "coverage_oracle_has_addon" \
  || _fail "coverage_oracle_has_addon" "$ORACLE missing eks.aws.m.upbound.io/Addon (regenerate with tests/coverage/derive-coverage.sh)"
DEFENDER="$(yq -r '.kinds["eks.aws.m.upbound.io/Addon"].defended_by // "null"' "$REGISTRY")"
[ -n "$DEFENDER" ] && [ "$DEFENDER" != "null" ] && [ -f "$DEFENDER" ] \
  && _pass "coverage_registry_defends_addon ($DEFENDER)" \
  || _fail "coverage_registry_defends_addon" "registry defended_by for eks.aws.m.upbound.io/Addon is '$DEFENDER' (missing file?)"
# Under the scoped verifier role an ungranted read is DENIED and the check
# lies about world state (live-verify run 28759141867 class).
for act in "eks:DescribeAddon" "eks:ListAddons"; do
  grep -q "\"$act\"" "$VERIFIER" \
    && _pass "verifier_policy_grants_$act" \
    || _fail "verifier_policy_grants_$act" "$VERIFIER does not grant $act"
done

assert_summary
