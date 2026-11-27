#!/usr/bin/env bash
# kp-2al.53 (owner, 2026-11-27): "When building kind and eks clusters make
# sure to use most recent version of add-ins and pin them."
#
# Every EKS managed add-on the platform installs is pinned to an exact
# version, set in ONE place per add-on:
#
#   terraform/management/variables.tf  eks_addon_versions (map add-on -> version)
#     -> hub cluster_addons (eks.tf)            addon_version = var.eks_addon_versions["<name>"]
#     -> cluster-network EnvironmentConfig      eksAddonVersions (crossplane-phase3.tf)
#        -> every composed spoke Addon          FromEnvironmentFieldPath eksAddonVersions[<name>], Required
#
# Red when: an add-on floats (most_recent, an Addon with no addonVersion), a
# version is set in a second place (a Composition literal), a pin is not an
# exact EKS version string, or the kube-proxy pin's minor differs from the
# Kubernetes version of a cluster it is installed on (kube-proxy is built per
# Kubernetes minor; EKS rejects a mismatched one).

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

VARS_TF="terraform/management/variables.tf"
EKS_TF="terraform/management/eks.tf"
ENV_TF="terraform/management/crossplane-phase3.tf"
PT='.spec.pipeline[] | select(.step == "patch-and-transform") | .input'
PIN_RE='^v[0-9]+\.[0-9]+\.[0-9]+-eksbuild\.[0-9]+$'

# The add-ons the hub installs as managed add-ons, and the ones every spoke
# installs (platform-cluster + XSpokeAccess Compositions together).
HUB_ADDONS="vpc-cni coredns kube-proxy"
SPOKE_ADDONS="vpc-cni coredns kube-proxy aws-ebs-csi-driver"

# The pin reader the live check uses (tests/live/lib/live-lib.sh) — tested
# here so the live check and this test agree on what "the pin" is.
pin() { ( . tests/live/lib/live-lib.sh; eks_addon_pin "$1" ) 2>/dev/null; }

# ---- 1. one pin per add-on, each an exact EKS version ---------------------
for a in $SPOKE_ADDONS; do
  v=$(pin "$a")
  if printf '%s' "$v" | grep -qE "$PIN_RE"; then
    _pass "pin_is_exact_version:$a ($v)"
  else
    _fail "pin_is_exact_version:$a" "eks_addon_versions[\"$a\"] in $VARS_TF is '$v' (want vX.Y.Z-eksbuild.N)"
  fi
done

# ---- 2. hub: no floating add-on, each pinned from the variable ------------
if grep -qE '^[^#]*most_recent' "$EKS_TF"; then
  _fail "hub_no_most_recent" "$EKS_TF still sets most_recent (the add-on floats)"
else
  _pass "hub_no_most_recent"
fi
for a in $HUB_ADDONS; do
  block=$(awk -v a="$a" '
    $0 ~ "^[[:space:]]*\"?" a "\"?[[:space:]]*=[[:space:]]*\\{" { on = 1; depth = 0 }
    on { print; depth += gsub(/\{/, "{"); depth -= gsub(/\}/, "}"); if (depth == 0) exit }
  ' "$EKS_TF")
  want="addon_version = var.eks_addon_versions[\"$a\"]"
  if printf '%s' "$block" | tr -s ' ' | grep -qF "$want"; then
    _pass "hub_addon_pinned:$a"
  else
    _fail "hub_addon_pinned:$a" "$EKS_TF cluster_addons has no '$a' block with: $want"
  fi
done

# ---- 3. the EnvironmentConfig publishes the same map ----------------------
if grep -qE 'eksAddonVersions[[:space:]]*=[[:space:]]*var\.eks_addon_versions' "$ENV_TF"; then
  _pass "envconfig_publishes_eks_addon_versions"
else
  _fail "envconfig_publishes_eks_addon_versions" "$ENV_TF cluster-network data lacks eksAddonVersions = var.eks_addon_versions"
fi

# ---- 4. every composed Addon takes its version from the environment ------
seen=""
for comp in crossplane/compositions/*.yaml; do
  names=$(yq -r "${PT}.resources[] | select(.base.kind == \"Addon\") | .name" "$comp" 2>/dev/null)
  for r in $names; do
    sel="${PT}.resources[] | select(.name == \"$r\")"
    addon=$(yq -r "$sel | .base.spec.forProvider.addonName // \"\"" "$comp")
    seen="$seen $addon"
    lit=$(yq -r "$sel | .base.spec.forProvider.addonVersion // \"absent\"" "$comp")
    assert_eq "no_version_literal:$(basename "$comp"):$r" "absent" "$lit"
    p=$(yq -r "$sel | .patches[] | select(.toFieldPath == \"spec.forProvider.addonVersion\") | [.type, .fromFieldPath, (.policy.fromFieldPath // \"\")] | join(\"|\")" "$comp")
    assert_eq "version_from_env_required:$(basename "$comp"):$r" \
      "FromEnvironmentFieldPath|eksAddonVersions[$addon]|Required" "$p"
    v=$(pin "$addon")
    if [ -n "$v" ]; then
      _pass "composed_addon_has_pin:$addon"
    else
      _fail "composed_addon_has_pin:$addon" "no eks_addon_versions[\"$addon\"] in $VARS_TF"
    fi
  done
done
for a in $SPOKE_ADDONS; do
  if printf "%s\n" "${seen# }" | tr " " "\n" | grep -qx "$a"; then
    _pass "spoke_composes_managed_addon:$a"
  else
    _fail "spoke_composes_managed_addon:$a" "no Composition composes an Addon for $a (EKS installs a self-managed copy that never updates)"
  fi
done

# ---- 5. kube-proxy matches every cluster's Kubernetes minor ---------------
kp=$(pin kube-proxy)
kp_minor=$(printf '%s' "$kp" | sed -nE 's/^v([0-9]+\.[0-9]+)\..*/\1/p')
hub_v=$(awk '/^variable "cluster_version"/{on=1} on && /default/{gsub(/[" ]/,"",$0); sub(/default=/,""); print; exit}' "$VARS_TF")
assert_eq "kube_proxy_matches_hub_version" "$hub_v" "$kp_minor"
while IFS= read -r f; do
  v=$(yq -r 'select(.kind == "XPlatformCluster") | .spec.version // ""' "$f")
  assert_eq "kube_proxy_matches_spoke_version:$f" "$v" "$kp_minor"
done < <(grep -rl '^kind: XPlatformCluster' clusters crossplane/claims)

# ---- 6. behaviour: no pin, no Addon (the Required policy) -----------------
if command -v crossplane >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  for x in platform-cluster xspokeaccess; do
    fx="crossplane/xrds/$x/render-fixtures"
    n=$(grep -c '^kind: Addon' "$fx/expected.yaml" || true)
    if [ "$n" -gt 0 ]; then
      _pass "golden_composes_addons:$x ($n)"
    else
      _fail "golden_composes_addons:$x" "$fx/expected.yaml has no Addon"
    fi
    rm -rf "${tmp:?}/$x"; mkdir -p "$tmp/$x"
    cp "$fx/input.yaml" "$tmp/$x/input.yaml"
    yq 'del(.data.eksAddonVersions)' "$fx/required-resources.yaml" > "$tmp/$x/required-resources.yaml"
    out=$(scripts/composition-render.sh --xrd "crossplane/xrds/$x.yaml" \
      --comp "crossplane/compositions/$x.yaml" --fixtures "$tmp/$x" 2>/dev/null)
    n=$(printf '%s\n' "$out" | grep -c '^kind: Addon' || true)
    assert_eq "missing_pin_composes_no_addon:$x" "0" "$n"
  done
else
  echo "  SKIP: render behaviour (crossplane CLI or docker absent)"
fi

assert_summary
