#!/usr/bin/env bash
# Owner rule (2026-11-26): node instance types are configurable in ONE place
# for every cluster, and each cluster's Kubernetes version in ONE place.
#
#   node type   terraform/management/variables.tf node_instance_type
#               -> hub node group (eks.tf)
#               -> cluster-network EnvironmentConfig nodeInstanceTypes
#                  (crossplane-phase3.tf) -> every spoke NodeGroup
#   version     hub:    terraform/management/variables.tf cluster_version
#               spokes: each XPlatformCluster's spec.version (required,
#                       no XRD default, no Composition literal)
#
# Any second place a value could be set (an XR field, an XRD default, a
# Composition base literal) is a regression this test turns red.

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

XRD="crossplane/xrds/platform-cluster.yaml"
COMP="crossplane/compositions/platform-cluster.yaml"
EKS_TF="terraform/management/eks.tf"
ENV_TF="terraform/management/crossplane-phase3.tf"
FIXTURES="crossplane/xrds/platform-cluster/render-fixtures"
PT='.spec.pipeline[] | select(.step == "patch-and-transform") | .input'
SPEC='.spec.versions[0].schema.openAPIV3Schema.properties.spec'

# ---- node type: terraform is the single source ---------------------------
grep -qE 'instance_types\s*=\s*\[var\.node_instance_type\]' "$EKS_TF" \
  && _pass "hub_node_group_uses_node_instance_type" \
  || _fail "hub_node_group_uses_node_instance_type" "$EKS_TF does not set instance_types = [var.node_instance_type]"

grep -qE 'nodeInstanceTypes\s*=\s*\[var\.node_instance_type\]' "$ENV_TF" \
  && _pass "envconfig_publishes_node_instance_type" \
  || _fail "envconfig_publishes_node_instance_type" "$ENV_TF cluster-network data lacks nodeInstanceTypes = [var.node_instance_type]"

# The spoke NodeGroup takes its types from the environment, Required.
NG_PATCH=$(yq -r "${PT}.resources[] | select(.name == \"eks-nodegroup\") | .patches[] | select(.toFieldPath == \"spec.forProvider.instanceTypes\") | [.type, .fromFieldPath, (.policy.fromFieldPath // \"\")] | join(\"|\")" "$COMP")
assert_eq "nodegroup_instance_types_from_env_required" \
  "FromEnvironmentFieldPath|nodeInstanceTypes|Required" "$NG_PATCH"

NG_BASE=$(yq -r "${PT}.resources[] | select(.name == \"eks-nodegroup\") | .base.spec.forProvider.instanceTypes // \"absent\"" "$COMP")
assert_eq "nodegroup_base_has_no_instance_type_literal" "absent" "$NG_BASE"

XRD_IT=$(yq -r "${SPEC}.properties.nodeGroup.properties.instanceTypes // \"absent\"" "$XRD")
assert_eq "xrd_has_no_instance_types_field" "absent" "$XRD_IT"

# No XR in git sets an instance type (it would be pruned, and it misleads).
hits=$(grep -rln 'instanceTypes' clusters crossplane/claims "$FIXTURES/input.yaml" 2>/dev/null || true)
[ -z "$hits" ] \
  && _pass "no_xr_sets_instance_types" \
  || _fail "no_xr_sets_instance_types" "instanceTypes still set in: $hits"

# ---- version: one place per cluster ---------------------------------------
grep -qE 'cluster_version\s*=\s*var\.cluster_version' "$EKS_TF" \
  && _pass "hub_version_from_cluster_version_var" \
  || _fail "hub_version_from_cluster_version_var" "$EKS_TF does not use var.cluster_version"

yq -r "${SPEC}.required[]" "$XRD" | grep -qx 'version' \
  && _pass "xrd_version_required" \
  || _fail "xrd_version_required" "spec.version is not required"

XRD_VDEF=$(yq -r "${SPEC}.properties.version.default // \"absent\"" "$XRD")
assert_eq "xrd_version_has_no_default" "absent" "$XRD_VDEF"

CL_BASE=$(yq -r "${PT}.resources[] | select(.name == \"eks-cluster\") | .base.spec.forProvider.version // \"absent\"" "$COMP")
assert_eq "cluster_base_has_no_version_literal" "absent" "$CL_BASE"

CL_PATCH=$(yq -r "${PT}.resources[] | select(.name == \"eks-cluster\") | .patches[] | select(.toFieldPath == \"spec.forProvider.version\") | .fromFieldPath" "$COMP")
assert_eq "cluster_version_from_xr" "spec.version" "$CL_PATCH"

# Every XPlatformCluster in git states its own version.
for f in $(grep -rl '^kind: XPlatformCluster' clusters crossplane/claims); do
  v=$(yq -r 'select(.kind == "XPlatformCluster") | .spec.version // ""' "$f")
  [ -n "$v" ] \
    && _pass "xr_sets_version:$f" \
    || _fail "xr_sets_version:$f" "no spec.version"
done

# ---- behaviour: a missing node type composes NO NodeGroup -----------------
# Guards the Required policy: without it, an absent nodeInstanceTypes would
# render a NodeGroup with no type and EKS would silently pick its default.
if command -v crossplane >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cp "$FIXTURES/input.yaml" "$tmp/input.yaml"
  yq 'del(.data.nodeInstanceTypes)' "$FIXTURES/required-resources.yaml" > "$tmp/required-resources.yaml"
  out=$(scripts/composition-render.sh --xrd "$XRD" --comp "$COMP" --fixtures "$tmp" 2>/dev/null)
  n=$(printf '%s\n' "$out" | grep -c '^kind: NodeGroup' || true)
  assert_eq "missing_node_type_composes_no_nodegroup" "0" "$n"
  n=$(grep -c '^kind: NodeGroup' "$FIXTURES/expected.yaml" || true)
  assert_eq "golden_composes_one_nodegroup" "1" "$n"
else
  echo "  SKIP: missing_node_type_composes_no_nodegroup (crossplane CLI or docker absent)"
fi

assert_summary
