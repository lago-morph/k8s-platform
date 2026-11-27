#!/usr/bin/env bash
# kp-2al.45: logs that cannot be reached any other way must be reachable.
#
# EKS control-plane logs (the API server's audit trail above all) exist ONLY
# if the cluster ships them to CloudWatch; there is no kubectl path to them.
# Owner rule (2026-11-27): monitoring is not a step-3 concern EXCEPT such logs.
#
#   hub    terraform/management/eks.tf          module inputs, explicit
#   spokes crossplane/compositions/platform-cluster.yaml  enabledClusterLogTypes
#   retention, bounded, ONE place: var.control_plane_log_retention_days
#     hub:    the eks module's own log group (module default is 90 days)
#     spokes: EKS creates /aws/eks/<name>/cluster with NEVER-EXPIRE retention
#             unless the group already exists, so terraform/management
#             pre-creates one per XPlatformCluster found under clusters/
#             (single source: the XR files ArgoCD syncs).

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

EKS_TF="terraform/management/eks.tf"
LOGS_TF="terraform/management/control-plane-logs.tf"
VARS_TF="terraform/management/variables.tf"
COMP="crossplane/compositions/platform-cluster.yaml"
GOLDEN="crossplane/xrds/platform-cluster/render-fixtures/expected.yaml"
SCHEMA="kubeconform-schemas/eks.aws.m.upbound.io/cluster_v1beta1.json"
PT='.spec.pipeline[] | select(.step == "patch-and-transform") | .input'
REQUIRED_TYPES="api audit authenticator"
MAX_RETENTION=14
# CloudWatch Logs accepts only these retention values.
VALID_RETENTION=" 1 3 5 7 14 30 60 90 120 150 180 365 400 545 731 1096 1827 2192 2557 2922 3288 3653 "

echo "== control-plane logging (kp-2al.45) =="

# ---- retention: one bounded variable --------------------------------------
ret=$(awk '/^variable "control_plane_log_retention_days"/{f=1} f&&/^[[:space:]]*default[[:space:]]*=/{print $3; exit}' "$VARS_TF" 2>/dev/null)
echo "  retention variable default: '${ret:-absent}'"
if [ -n "$ret" ] && [[ "$VALID_RETENTION" == *" $ret "* ]] && [ "$ret" -le "$MAX_RETENTION" ]; then
  _pass "retention_var_bounded_and_valid"
else
  _fail "retention_var_bounded_and_valid" "$VARS_TF: control_plane_log_retention_days default must be a CloudWatch value <= $MAX_RETENTION (got '${ret:-absent}')"
fi

# ---- hub: explicit log types + retention from the variable ----------------
hub_types=$(grep -E '^\s*cluster_enabled_log_types\s*=' "$EKS_TF" || true)
echo "  hub: ${hub_types:-cluster_enabled_log_types not set}"
for t in $REQUIRED_TYPES; do
  [[ "$hub_types" == *"\"$t\""* ]] \
    && _pass "hub_log_type:$t" \
    || _fail "hub_log_type:$t" "$EKS_TF must pin cluster_enabled_log_types including \"$t\""
done
grep -qE '^\s*cloudwatch_log_group_retention_in_days\s*=\s*var\.control_plane_log_retention_days' "$EKS_TF" \
  && _pass "hub_retention_from_var" \
  || _fail "hub_retention_from_var" "$EKS_TF must set cloudwatch_log_group_retention_in_days = var.control_plane_log_retention_days (module default is 90)"
grep -qE '^\s*create_cloudwatch_log_group\s*=\s*false' "$EKS_TF" \
  && _fail "hub_module_owns_log_group" "create_cloudwatch_log_group = false hands the group to EKS (never-expire)" \
  || _pass "hub_module_owns_log_group"

# ---- spokes: the Composition enables the log types ------------------------
if jq -e '.properties.spec.properties.forProvider.properties.enabledClusterLogTypes' "$SCHEMA" >/dev/null 2>&1; then
  _pass "schema_has_enabledClusterLogTypes"
else
  _fail "schema_has_enabledClusterLogTypes" "$SCHEMA lacks forProvider.enabledClusterLogTypes"
fi
spoke_types=$(yq -r "${PT}.resources[] | select(.name == \"eks-cluster\") | .base.spec.forProvider.enabledClusterLogTypes // [] | .[]" "$COMP" | sort | tr '\n' ' ')
echo "  spoke Composition: ${spoke_types:-no enabledClusterLogTypes}"
# The golden is a normalized stream without `---` separators: walk it as
# text. A document starts at `apiVersion:`; collect the list items under
# enabledClusterLogTypes inside the eks Cluster document only.
golden_types=$(awk '
  /^apiVersion:/ { eks = ($2 == "eks.aws.m.upbound.io/v1beta1"); cl = 0; inl = 0 }
  /^kind: Cluster$/ { cl = eks }
  cl && /^[[:space:]]+enabledClusterLogTypes:/ { inl = 1; next }
  inl && /^[[:space:]]+- / { print $2; next }
  { inl = 0 }
' "$GOLDEN" | sort | tr '\n' ' ')
echo "  spoke render golden: ${golden_types:-no enabledClusterLogTypes}"
for t in $REQUIRED_TYPES; do
  [[ " $spoke_types" == *" $t "* ]] \
    && _pass "spoke_log_type:$t" \
    || _fail "spoke_log_type:$t" "$COMP eks-cluster base lacks enabledClusterLogTypes \"$t\""
  [[ " $golden_types" == *" $t "* ]] \
    && _pass "golden_log_type:$t" \
    || _fail "golden_log_type:$t" "$GOLDEN Cluster lacks enabledClusterLogTypes \"$t\" (regenerate the golden)"
done

# ---- spokes: bounded retention via a pre-created log group ----------------
if [ -f "$LOGS_TF" ]; then
  _pass "spoke_log_group_file_present"
  grep -qE 'resource "aws_cloudwatch_log_group" "spoke_control_plane"' "$LOGS_TF" \
    && _pass "spoke_log_group_resource" \
    || _fail "spoke_log_group_resource" "$LOGS_TF lacks aws_cloudwatch_log_group.spoke_control_plane"
  grep -qF 'name              = "/aws/eks/${each.key}/cluster"' "$LOGS_TF" \
    && _pass "spoke_log_group_is_eks_name" \
    || _fail "spoke_log_group_is_eks_name" "the group must be named exactly /aws/eks/<cluster>/cluster or EKS creates its own"
  grep -qE 'retention_in_days\s*=\s*var\.control_plane_log_retention_days' "$LOGS_TF" \
    && _pass "spoke_retention_from_var" \
    || _fail "spoke_retention_from_var" "$LOGS_TF retention must come from var.control_plane_log_retention_days"
  grep -qF '"${path.module}/../../clusters"' "$LOGS_TF" \
    && _pass "spoke_names_read_from_clusters_dir" \
    || _fail "spoke_names_read_from_clusters_dir" "$LOGS_TF must discover spoke names from clusters/ (single source)"
else
  _fail "spoke_log_group_file_present" "$LOGS_TF missing: EKS would create the spoke group with never-expire retention"
fi

# terraform yamldecode()s each XR file: it must be ONE document carrying
# spec.name, or the management plan fails / silently misses a spoke.
n=0
for f in $(grep -rlE '^kind: XPlatformCluster$' clusters); do
  n=$((n + 1))
  docs=$(yq -r 'document_index' "$f" | sort -u | wc -l)
  name=$(yq -r '.spec.name // ""' "$f")
  echo "  spoke XR $f -> /aws/eks/${name:-?}/cluster"
  [ "$docs" -eq 1 ] && [ -n "$name" ] \
    && _pass "spoke_xr_decodable:$f" \
    || _fail "spoke_xr_decodable:$f" "must be a single YAML document with spec.name (docs=$docs name='$name')"
done
[ "$n" -gt 0 ] \
  && _pass "spoke_xrs_found ($n)" \
  || _fail "spoke_xrs_found" "no XPlatformCluster under clusters/"

assert_summary
