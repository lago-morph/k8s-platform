#!/usr/bin/env bash
# Cross-file version-pin consistency (L31). Pins that must move together
# live adjacent in versions.env as the single source; where a duplicate is
# unavoidable (terraform variable defaults cannot source an env file),
# this lint holds the copies equal so a bump cannot split the pair.
#
# Grounded in retro 2026-06-10-218: the kubeconform argo CRD store was
# generated from ArgoCD v2.13.1 while the deployed chart (6.7.3) ships
# v2.10.4 — a silent three-minor skew that lived as long as the store did,
# meaning kubeconform validated manifests against a controller that was
# not the one admitting them.
#
# Future cross-file pin pairs join THIS file — do not spawn per-pair
# sibling tests.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
FAIL=0

VERSIONS_ENV="$ROOT/versions.env"
[ -f "$VERSIONS_ENV" ] || { echo "FAIL: versions.env missing"; exit 1; }
# shellcheck disable=SC1090
. "$VERSIONS_ENV"

# ── ArgoCD chart/app pair ────────────────────────────────────────────────

# Both halves of the pair must be pinned.
for var in ARGOCD_CHART_VERSION ARGOCD_APP_VERSION; do
  val="$(eval "printf '%s' \"\${$var:-}\"")"
  if [ -n "$val" ]; then
    echo "ok: versions.env pins $var=$val"
  else
    echo "FAIL: versions.env must pin $var (the ArgoCD chart/app paired pin)"; FAIL=1
  fi
done

# 1. The terraform chart default (the unavoidable duplicate) equals the
#    single source.
TF_VARS="$ROOT/terraform/management/variables.tf"
tf_chart="$(awk '/variable "argocd_version"/,/^}/' "$TF_VARS" \
  | grep -E '^\s*default' | sed -E 's/.*"([^"]+)".*/\1/')"
if [ "$tf_chart" = "${ARGOCD_CHART_VERSION:-}" ]; then
  echo "ok: variables.tf argocd_version default ($tf_chart) == ARGOCD_CHART_VERSION"
else
  echo "FAIL: variables.tf argocd_version default ('$tf_chart') != versions.env ARGOCD_CHART_VERSION ('${ARGOCD_CHART_VERSION:-}')."
  echo "      These are the same chart pin in two files (terraform cannot source"
  echo "      versions.env). Bump them together — and when the chart version"
  echo "      changes, ARGOCD_APP_VERSION must be updated to that chart's"
  echo "      appVersion (argo-helm Chart.yaml) in the same commit."
  FAIL=1
fi

# 2. The kubeconform CRD fetch script must take its argo pin FROM the
#    single source — no hardcoded argoproj/argo-cd version may reappear.
FETCH="$ROOT/scripts/fetch-crds-for-kubeconform.sh"
if hard="$(grep -nE 'argoproj/argo-cd/v[0-9]+\.[0-9]+' "$FETCH")"; then
  echo "FAIL: hardcoded argoproj/argo-cd version in fetch-crds-for-kubeconform.sh"
  echo "      (must interpolate \${ARGOCD_APP_VERSION} from versions.env):"
  echo "$hard"
  FAIL=1
else
  echo "ok: fetch script has no hardcoded argo-cd version"
fi
if grep -q 'argo-cd/\${ARGOCD_APP_VERSION}/manifests/crds/' "$FETCH"; then
  echo "ok: fetch script interpolates ARGOCD_APP_VERSION for the argo CRD URLs"
else
  echo "FAIL: fetch script does not use \${ARGOCD_APP_VERSION} for the argoproj CRD URLs"; FAIL=1
fi

# ── ingress-nginx hub/spoke pair ─────────────────────────────────────────
# The hub (terraform helm_release, variables.tf `ingress_nginx_version`) and
# every spoke (ApplicationSet argocd/apps/spoke/ingress-nginx.yaml) install
# the SAME controller from the same chart. Neither file can source the other,
# so this lint holds them equal: a bump that moves one side leaves the other
# on a controller with different CVE exposure and different admission
# behaviour (kp-uvy.10: 4.10.0 -> 4.15.1 changed annotation validation and
# path-type strictness — the hub and spokes must never disagree on that).
# terraform.tfvars.example documents the same pin and must not drift either.
tf_ingress="$(awk '/variable "ingress_nginx_version"/,/^}/' "$TF_VARS" \
  | grep -E '^\s*default' | sed -E 's/.*"([^"]+)".*/\1/')"
SPOKE_APPSET="$ROOT/argocd/apps/spoke/ingress-nginx.yaml"
spoke_ingress="$(yq -r '.spec.template.spec.sources[] | select(.chart=="ingress-nginx") | .targetRevision' "$SPOKE_APPSET" 2>/dev/null)"
TFVARS_EXAMPLE="$ROOT/terraform/management/terraform.tfvars.example"
example_ingress="$(grep -E '^\s*ingress_nginx_version\s*=' "$TFVARS_EXAMPLE" | sed -E 's/.*"([^"]+)".*/\1/')"
if [ -z "$tf_ingress" ]; then
  echo "FAIL: could not read variables.tf ingress_nginx_version default"; FAIL=1
elif [ "$spoke_ingress" = "$tf_ingress" ]; then
  echo "ok: spoke ApplicationSet ingress-nginx targetRevision ($spoke_ingress) == hub variables.tf default"
else
  echo "FAIL: ingress-nginx hub/spoke split: variables.tf default '$tf_ingress'"
  echo "      != argocd/apps/spoke/ingress-nginx.yaml targetRevision '$spoke_ingress'."
  echo "      Hub and spoke run one controller version; bump both together."
  FAIL=1
fi
if [ -n "$tf_ingress" ] && [ "$example_ingress" = "$tf_ingress" ]; then
  echo "ok: terraform.tfvars.example ingress_nginx_version ($example_ingress) == variables.tf default"
else
  echo "FAIL: terraform.tfvars.example ingress_nginx_version '$example_ingress' != variables.tf default '$tf_ingress'"
  FAIL=1
fi

[ "$FAIL" -eq 0 ] && echo "PASS: version-pin consistency" || echo "FAILED"
exit "$FAIL"
