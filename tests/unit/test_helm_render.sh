#!/usr/bin/env bash
# Render every helm_release in terraform/management/helm.tf and assert that
# the produced manifests carry the contracts we depend on.
#
# Catches the bug class "wrong chart key, silently ignored" (bugs #3, #5, #7
# from the 2026-05-23 phase-1 bring-up). Runs in <30s with no AWS / no cluster.
#
# Each chart block defines the same set blocks helm.tf uses (mirrored, with
# IRSA/domain placeholders) and asserts the rendered output meets the
# contract we expect. If helm.tf drifts, test_helm_drift.sh below catches it.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

require_tool helm
require_tool yq

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stub values used in place of terraform interpolations.
STUB_DOMAIN="example.com"
STUB_REGION="us-east-1"
STUB_ARGOCD_IRSA="arn:aws:iam::000000000000:role/test-argocd"
STUB_ESO_IRSA="arn:aws:iam::000000000000:role/test-eso"
STUB_EDNS_IRSA="arn:aws:iam::000000000000:role/test-external-dns"
STUB_ACM_ARN="arn:aws:acm:us-east-1:000000000000:certificate/stub"

# Versions match terraform/management/variables.tf defaults.
# Argo CD comes from the single source (versions.env ARGOCD_CHART_VERSION,
# held equal to variables.tf argocd_version by
# test_version_pin_consistency.sh), so this render can never test a
# different chart than the one terraform installs.
# shellcheck disable=SC1091
. "$HERE/../../versions.env"
ARGOCD_VERSION="${ARGOCD_CHART_VERSION}"
CROSSPLANE_VERSION="2.0.1"   # not rendered here; crossplane has no values
ESO_VERSION="0.9.13"
# ingress-nginx is read from its single hub source (variables.tf) rather than
# copied here, so this render can never test a different chart than the one
# terraform installs; test_version_pin_consistency.sh holds the spoke
# ApplicationSet targetRevision equal to the same value.
INGRESS_NGINX_VERSION="$(awk '/variable "ingress_nginx_version"/,/^}/' \
  "$HERE/../../terraform/management/variables.tf" \
  | grep -E '^\s*default' | sed -E 's/.*"([^"]+)".*/\1/')"
EXTERNAL_DNS_VERSION="1.15.0"

echo "── helm-render: argocd ────────────────────────────────────────────"
# The argocd --set list is READ from helm.tf's helm_release.argocd set{}
# blocks (no hand-kept mirror to drift), so this render is what terraform
# installs. Terraform interpolations become stubs (the IRSA role ARN,
# ${var.domain}); HCL's "\\." escapes become helm's "\.".
ARGOCD_SETS=()
while IFS=$'\t' read -r n v; do
  [ -n "$n" ] || continue
  n="${n#\"}"; n="${n%\"}"; n="${n//\\\\/\\}"
  case "$v" in
    module.irsa_argocd.iam_role_arn) v="$STUB_ARGOCD_IRSA" ;;
    *) v="${v#\"}"; v="${v%\"}"; v="${v//\$\{var.domain\}/$STUB_DOMAIN}" ;;
  esac
  ARGOCD_SETS+=("$n=$v")
done < <(awk '/^resource "helm_release" "argocd"/,/^}/' "$HERE/../../terraform/management/helm.tf" | awk '
  /^[[:space:]]*set[[:space:]]*\{/ {inset=1; n=""; v=""; next}
  inset && /^[[:space:]]*name[[:space:]]*=/  {sub(/^[^=]*=[[:space:]]*/, ""); n=$0}
  inset && /^[[:space:]]*value[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); v=$0}
  inset && /^[[:space:]]*\}/ {inset=0; print n "\t" v}')
if [ "${#ARGOCD_SETS[@]}" -ge 5 ]; then
  pass "argocd: read ${#ARGOCD_SETS[@]} set{} blocks from helm.tf helm_release.argocd"
else
  fail "argocd: could not read the set{} blocks from helm.tf helm_release.argocd" "${ARGOCD_SETS[*]:-none}"
fi
OUT="$TMP/argocd.yaml"
if helm_render \
  "https://argoproj.github.io/argo-helm" \
  "argo-cd" \
  "$ARGOCD_VERSION" \
  "$OUT" \
  "${ARGOCD_SETS[@]}"; then
  # The argocd-server ServiceAccount must carry the IRSA annotation.
  assert_yq_eq "$OUT" \
    'select(.kind=="ServiceAccount" and .metadata.name=="argocd-server") | .metadata.annotations["eks.amazonaws.com/role-arn"]' \
    "$STUB_ARGOCD_IRSA" \
    "argocd: argocd-server SA has IRSA annotation"

  # The application-controller SA carries the same IRSA role (auto-012: it
  # runs argocd-k8s-auth against the spoke clusters).
  assert_yq_eq "$OUT" \
    'select(.kind=="ServiceAccount" and .metadata.name=="argocd-application-controller") | .metadata.annotations["eks.amazonaws.com/role-arn"] // ""' \
    "$STUB_ARGOCD_IRSA" \
    "argocd: application-controller SA has the IRSA annotation"

  # Argo CD 3.0 stopped persisting per-resource health in the Application
  # CR (.status.resources[].health). scripts/argocd-apps.sh and the
  # phase-2-diagnose workflow read it with kubectl, so helm.tf turns
  # persistence back on (kp-2al.56).
  assert_yq_eq "$OUT" \
    'select(.kind=="ConfigMap" and .metadata.name=="argocd-cmd-params-cm") | .data["controller.resource.health.persist"]' \
    "true" \
    "argocd: argocd-cmd-params-cm controller.resource.health.persist == true"

  # Ingress is enabled and host points at our subdomain. Select by
  # app.kubernetes.io/name=argocd-server because the chart prefixes Ingress
  # metadata.name with the release-name ("argo-cd-argocd-server") while the
  # label stays stable across release-name choices.
  assert_yq_matches "$OUT" \
    'select(.kind=="Ingress" and .metadata.labels["app.kubernetes.io/name"]=="argocd-server") | .spec.rules[0].host' \
    "^argocd\.management\.$STUB_DOMAIN$" \
    "argocd: Ingress host == argocd.management.$STUB_DOMAIN"

  # external-dns annotation on the Ingress matches hostname (so ExternalDNS picks it up).
  assert_yq_eq "$OUT" \
    'select(.kind=="Ingress" and .metadata.labels["app.kubernetes.io/name"]=="argocd-server") | .metadata.annotations["external-dns.alpha.kubernetes.io/hostname"]' \
    "argocd.management.$STUB_DOMAIN" \
    "argocd: Ingress external-dns hostname annotation == subdomain"

  # Ingress class is nginx.
  assert_yq_eq "$OUT" \
    'select(.kind=="Ingress" and .metadata.labels["app.kubernetes.io/name"]=="argocd-server") | .spec.ingressClassName' \
    "nginx" \
    "argocd: Ingress ingressClassName == nginx"

  # argocd-server runs with --insecure (TLS terminates at NLB). Use
  # `// []` fallbacks because Mike Farah yq's `null + [...]` collapses
  # to null (the chart sets args but not command on this container).
  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.labels["app.kubernetes.io/name"]=="argocd-server") | ((.spec.template.spec.containers[0].command // []) + (.spec.template.spec.containers[0].args // [])) | .[]' \
    "(^|=)--insecure" \
    "argocd: argocd-server runs with --insecure"
else
  fail "argocd: helm template failed" "$(cat "$OUT.err" 2>/dev/null | tail -10)"
fi

echo "── helm-render: external-dns ─────────────────────────────────────"
OUT="$TMP/external-dns.yaml"
if helm_render \
  "https://kubernetes-sigs.github.io/external-dns/" \
  "external-dns" \
  "$EXTERNAL_DNS_VERSION" \
  "$OUT" \
  "provider.name=aws" \
  "policy=upsert-only" \
  "domainFilters[0]=$STUB_DOMAIN" \
  "txtOwnerId=k8-platform-mgmt" \
  "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$STUB_EDNS_IRSA" \
  "sources[0]=ingress" \
  "sources[1]=service" \
  "env[0].name=AWS_REGION" \
  "env[0].value=$STUB_REGION"; then

  assert_yq_eq "$OUT" \
    'select(.kind=="ServiceAccount" and .metadata.name=="external-dns") | .metadata.annotations["eks.amazonaws.com/role-arn"]' \
    "$STUB_EDNS_IRSA" \
    "external-dns: SA has IRSA annotation"

  # Pod args must include the AWS provider.
  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].args | .[]' \
    "^--provider=aws$" \
    "external-dns: pod arg --provider=aws"

  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].args | .[]' \
    "^--domain-filter=$STUB_DOMAIN$" \
    "external-dns: pod arg --domain-filter=$STUB_DOMAIN"

  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].args | .[]' \
    "^--policy=upsert-only$" \
    "external-dns: pod arg --policy=upsert-only"

  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].args | .[]' \
    "^--source=ingress$" \
    "external-dns: pod arg --source=ingress"

  assert_yq_eq "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].env[] | select(.name=="AWS_REGION") | .value' \
    "$STUB_REGION" \
    "external-dns: AWS_REGION env set"
else
  fail "external-dns: helm template failed" "$(cat "$OUT.err" 2>/dev/null | tail -10)"
fi

echo "── helm-render: external-secrets ─────────────────────────────────"
OUT="$TMP/eso.yaml"
if helm_render \
  "https://charts.external-secrets.io" \
  "external-secrets" \
  "$ESO_VERSION" \
  "$OUT" \
  "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$STUB_ESO_IRSA"; then

  assert_yq_eq "$OUT" \
    'select(.kind=="ServiceAccount" and .metadata.name=="external-secrets") | .metadata.annotations["eks.amazonaws.com/role-arn"]' \
    "$STUB_ESO_IRSA" \
    "eso: SA external-secrets has IRSA annotation"
else
  fail "eso: helm template failed" "$(cat "$OUT.err" 2>/dev/null | tail -10)"
fi

echo "── helm-render: ingress-nginx ────────────────────────────────────"
OUT="$TMP/ingress-nginx.yaml"
if helm_render \
  "https://kubernetes.github.io/ingress-nginx" \
  "ingress-nginx" \
  "$INGRESS_NGINX_VERSION" \
  "$OUT" \
  "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb" \
  "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-ssl-cert=$STUB_ACM_ARN" \
  "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-ssl-ports=443" \
  "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-backend-protocol=http" \
  "controller.service.targetPorts.https=http"; then

  # Service has the NLB annotation set.
  assert_yq_eq "$OUT" \
    'select(.kind=="Service" and .metadata.name=="ingress-nginx-controller") | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-type"]' \
    "nlb" \
    "ingress-nginx: Service has aws-load-balancer-type=nlb"

  assert_yq_eq "$OUT" \
    'select(.kind=="Service" and .metadata.name=="ingress-nginx-controller") | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-ssl-cert"]' \
    "$STUB_ACM_ARN" \
    "ingress-nginx: Service has the ACM cert annotation"

  # Port 443 targets the http port (NLB terminates TLS, nginx serves plain HTTP).
  assert_yq_eq "$OUT" \
    'select(.kind=="Service" and .metadata.name=="ingress-nginx-controller") | .spec.ports[] | select(.name=="https") | .targetPort' \
    "http" \
    "ingress-nginx: port 443 (https) → targetPort http (TLS-termination at NLB)"
else
  fail "ingress-nginx: helm template failed" "$(cat "$OUT.err" 2>/dev/null | tail -10)"
fi

echo "── helm-render: ingress-nginx (spoke values file) ────────────────"
# The spoke installs the same chart through the ApplicationSet with
# platform-services/ingress/values.yaml. Render that file at the pinned
# version so a value the chart renamed/dropped, or an override that weakens
# the controller's admission defaults, is caught for the spoke too.
OUT="$TMP/ingress-nginx-spoke.yaml"
SPOKE_VALUES="$HERE/../../platform-services/ingress/values.yaml"
if helm template ingress-nginx ingress-nginx \
     --repo "https://kubernetes.github.io/ingress-nginx" \
     --version "$INGRESS_NGINX_VERSION" --namespace ingress-nginx \
     -f "$SPOKE_VALUES" > "$OUT" 2> "$OUT.err"; then

  assert_yq_eq "$OUT" \
    'select(.kind=="Service" and .metadata.name=="ingress-nginx-controller") | .spec.ports[] | select(.name=="https") | .targetPort' \
    "http" \
    "ingress-nginx spoke: port 443 (https) → targetPort http (TLS-termination at NLB)"

  assert_yq_eq "$OUT" \
    'select(.kind=="IngressClass") | .metadata.annotations["ingressclass.kubernetes.io/is-default-class"]' \
    "true" \
    "ingress-nginx spoke: IngressClass nginx is the default class"

  # CVE floor: CVE-2025-1974 ("IngressNightmare", unauthenticated RCE via the
  # admission webhook) and CVE-2025-1097/1098/24513/24514 are fixed in
  # controller v1.11.5 / v1.12.1. Anything older must not ship.
  image="$(yq -r 'select(.kind=="Deployment" and .metadata.name=="ingress-nginx-controller") | .spec.template.spec.containers[0].image' "$OUT")"
  tag="$(printf '%s' "$image" | sed -E 's/^[^:]+:(v[0-9.]+).*/\1/')"
  floor="v1.12.1"
  if [ "$(printf '%s\n%s\n' "$floor" "$tag" | sort -V | head -1)" = "$floor" ]; then
    pass "ingress-nginx spoke: controller $tag >= $floor (CVE-2025-1974 fixed)"
  else
    fail "ingress-nginx spoke: controller $tag < $floor — vulnerable to CVE-2025-1974 (IngressNightmare)" "$image"
  fi

  # The 1.12+ admission hardening must stay at the controller defaults:
  # annotation validation on (risk level High), strict path-type validation
  # on, snippets and cross-namespace references off. None of these may be
  # weakened by an override in our values.
  assert_not_grep 'enable-annotation-validation=false' "$OUT" \
    "ingress-nginx spoke: annotation validation not disabled"
  for key in annotations-risk-level strict-validate-path-type \
             allow-cross-namespace-resources allow-snippet-annotations; do
    val="$(yq -r "select(.kind==\"ConfigMap\" and .metadata.name==\"ingress-nginx-controller\") | .data[\"$key\"]" "$OUT" \
      | grep -vx -e '---' -e 'null' | head -1)"
    case "$key=$val" in
      *=|annotations-risk-level=High|annotations-risk-level=Medium|annotations-risk-level=Low|strict-validate-path-type=true|allow-cross-namespace-resources=false|allow-snippet-annotations=false)
        pass "ingress-nginx spoke: config $key not weakened ('${val:-default}')" ;;
      *)
        fail "ingress-nginx spoke: config $key=$val weakens 1.12+ admission defaults" ;;
    esac
  done
else
  fail "ingress-nginx spoke: helm template failed" "$(tail -10 "$OUT.err" 2>/dev/null)"
fi

echo "── ingress annotations: reviewed against 1.12+ risk validation ────"
# With --enable-annotation-validation and annotations-risk-level=High, the
# controller rejects any nginx.ingress.kubernetes.io/* annotation rated
# Critical. Every such annotation the platform sets is listed here with the
# risk the v1.15.1 source assigns it; a new one must be checked against
# internal/ingress/annotations/*/main.go and added deliberately.
REVIEWED_NGINX_ANNOTATIONS="proxy-body-size"   # Medium, value ^\d+[bkmg]?$
ROOT="$HERE/../.."
used="$(grep -rhoE 'nginx\.ingress\.kubernetes\.io/[a-z0-9-]+' \
  "$ROOT/argocd" "$ROOT/platform-services" "$ROOT/terraform" \
  "$ROOT/crossplane" "$ROOT/clusters" 2>/dev/null \
  | sed 's#.*/##' | sort -u)"
for a in $used; do
  if printf ' %s ' "$REVIEWED_NGINX_ANNOTATIONS" | grep -q " $a "; then
    pass "ingress annotation nginx.ingress.kubernetes.io/$a reviewed (allowed at risk level High)"
  else
    fail "ingress annotation nginx.ingress.kubernetes.io/$a not reviewed against 1.12+ annotation risk validation"
  fi
done

summary
