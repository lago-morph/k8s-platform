#!/usr/bin/env bash
# The pinned Argo CD release must be tested upstream on every Kubernetes
# version this repo deploys (kp-2al.56).
#
# Why: the test build on Kubernetes 1.37 (kp-2al.54) ran Argo CD v2.10.4,
# tested only on 1.25-1.28. It could not compare Deployments on the spoke —
# "ComparisonError: error building typed value from live resource:
# .status.terminatingReplicas: field not declared in schema" (the field is
# on by default from Kubernetes 1.35) — and left spoke-ingress-nginx waiting
# on a hook Job that had completed. Nothing in the repo tied the Argo CD pin
# to the cluster versions, so a Kubernetes bump could silently outrun it.
#
# The table below is copied from upstream
# docs/operator-manual/tested-kubernetes-versions.md at the pinned tag
# (https://github.com/argoproj/argo-cd/blob/<tag>/docs/operator-manual/tested-kubernetes-versions.md).
# When ARGOCD_APP_VERSION moves to a minor not listed here, add its row from
# that file — the test fails until you do, on purpose.
#
# Kubernetes versions deployed: the hub (terraform/management/variables.tf
# cluster_version) and every spoke XR (clusters/*/*.yaml XPlatformCluster
# spec.version).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/lib/test-helpers.sh"

# shellcheck disable=SC1091
. "$ROOT/versions.env"

# Argo CD minor -> Kubernetes minors it is tested on (upstream table).
tested_k8s_for() {
  case "$1" in
    2.10) echo "1.28 1.27 1.26 1.25" ;;
    3.4) echo "1.35 1.34 1.33 1.32" ;;
    3.5) echo "1.36 1.35 1.34 1.33" ;;
    3.6) echo "1.37 1.36 1.35 1.34" ;;
    *) echo "" ;;
  esac
}

echo "── argocd: pinned release is tested on every deployed Kubernetes version ──"

argo_minor="$(printf '%s' "${ARGOCD_APP_VERSION:-}" | sed -nE 's/^v([0-9]+\.[0-9]+)\..*/\1/p')"
if [ -z "$argo_minor" ]; then
  fail "argocd_app_version_parses" "versions.env ARGOCD_APP_VERSION='${ARGOCD_APP_VERSION:-}' is not vX.Y.Z"
  summary
fi
pass "argocd_app_version_parses ($ARGOCD_APP_VERSION -> $argo_minor)"

tested="$(tested_k8s_for "$argo_minor")"
if [ -z "$tested" ]; then
  fail "argocd_minor_in_table" "Argo CD $argo_minor has no row here; copy it from tested-kubernetes-versions.md at $ARGOCD_APP_VERSION"
  summary
fi
pass "argocd_minor_in_table ($argo_minor: $tested)"

# Collect "<where>=<k8s minor>" pairs.
deployed=()
hub="$(awk '/variable "cluster_version"/,/^}/' "$ROOT/terraform/management/variables.tf" \
  | grep -E '^\s*default' | sed -E 's/.*"([^"]+)".*/\1/')"
if [ -n "$hub" ]; then
  deployed+=("hub(terraform/management/variables.tf)=$hub")
else
  fail "hub_cluster_version_readable" "could not read cluster_version default"
fi
for f in "$ROOT"/clusters/*/*.yaml; do
  v="$(yq -r 'select(.kind=="XPlatformCluster") | .spec.version // ""' "$f" 2>/dev/null | grep -v '^---$' | head -n 1)"
  [ -n "$v" ] || continue
  deployed+=("spoke(${f#"$ROOT"/})=$v")
done
if [ "${#deployed[@]}" -lt 2 ]; then
  fail "found_deployed_versions" "expected the hub and at least one spoke XR, found: ${deployed[*]:-none}"
fi

for d in "${deployed[@]}"; do
  where="${d%%=*}"; v="${d#*=}"
  case " $tested " in
    *" $v "*) pass "kubernetes $v ($where) is tested with Argo CD $argo_minor" ;;
    *) fail "kubernetes $v ($where) is tested with Argo CD $argo_minor" \
         "Argo CD $ARGOCD_APP_VERSION is tested on Kubernetes $tested only — bump the Argo CD pin (versions.env, variables.tf argocd_version)" ;;
  esac
done

summary
