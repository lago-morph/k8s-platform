#!/usr/bin/env bash
# Owner rule (2026-11-27): every TLS listener accepts TLS 1.2 or better and
# negotiates the version with the client. The ingress NLBs terminate TLS, so
# each must carry an explicit SSL negotiation policy instead of the NLB
# default. ELBSecurityPolicy-TLS13-1-2-2021-06 offers TLS 1.3 and 1.2 only.
set -uo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
. tests/lib/assert.sh

POLICY="ELBSecurityPolicy-TLS13-1-2-2021-06"
ANN='aws-load-balancer-ssl-negotiation-policy'

# Hub: terraform/management/helm.tf sets annotations via helm `set` blocks.
hub="$(grep -A1 -F "$ANN" terraform/management/helm.tf | grep -o 'value *= *"[^"]*"' | head -1 | sed 's/.*"\(.*\)"/\1/')"
assert_eq "hub NLB negotiation policy" "$POLICY" "${hub:-NONE}"

# Spoke: platform-services/ingress/values.yaml (shared by every spoke).
spoke="$(yq -r '.controller.service.annotations["service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy"] // "NONE"' platform-services/ingress/values.yaml)"
assert_eq "spoke NLB negotiation policy" "$POLICY" "$spoke"

# No listener anywhere names a policy that allows TLS 1.0/1.1.
weak="$(git grep -n -E 'ELBSecurityPolicy-(2015|2016|TLS-1-0|TLS-1-1|FS-2018|FS-1-1)' -- terraform platform-services argocd crossplane clusters || true)"
[ -z "$weak" ] && _pass "no TLS 1.0/1.1 policy referenced" || _fail "no TLS 1.0/1.1 policy referenced" "$weak"

assert_summary
