#!/usr/bin/env bash
# Shared helpers for the ops-box bring-up scripts (kp-2al.34).
#
# THE DESIGN RULE, and it is load-bearing: these scripts ASK THE WORLD, NEVER
# GITHUB. Every stage check below is a describe against AWS or a read against
# the cluster, never "did the workflow run go green".
#
# Two reasons. First, a green check is not the same as a working platform:
# `[management] argocd-url` is continue-on-error, so it reports green while its
# own log says `FAIL: ArgoCD UI returned HTTP 000`. Second, asking the world
# means the box needs no GitHub token, which is what keeps it credential-free.
#
# A useful side effect: every check is idempotent and order-independent, so the
# driver is resumable. Re-run it after any interruption and it works out where
# it is.
set -uo pipefail

: "${AWS_PAGER:=}"
export AWS_PAGER

HUB_CLUSTER="${HUB_CLUSTER:-k8-platform-mgmt}"
SPOKE_CLUSTER="${SPOKE_CLUSTER:-k8-platform-services}"
OPSBOX_ROLE_NAME="${OPSBOX_ROLE_NAME:-k8-platform-opsbox}"

# ---- output ---------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m';  C_OFF=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_OFF=""
fi

green() { printf '%s  GREEN%s  %s\n' "$C_GREEN" "$C_OFF" "$1"; }
red()   { printf '%s    RED%s  %s\n' "$C_RED"   "$C_OFF" "$1"; }
wait_() { printf '%sWAITING%s  %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
info()  { printf '%s         %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
head_() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }

# say_do <text...> — the one thing the operator must go and do.
say_do() {
  printf '\n%s  ACTION NEEDED  %s\n' "$C_BOLD$C_YELLOW" "$C_OFF"
  while [ $# -gt 0 ]; do printf '  %s\n' "$1"; shift; done
  printf '\n'
}

# ---- account facts --------------------------------------------------------
account_id() { aws sts get-caller-identity --query Account --output text 2>/dev/null; }

# The domain is discovered, never configured — the same way the build
# discovers it. First public hosted zone wins.
platform_domain() {
  # SC2016: the backticks are JMESPath literals for the AWS CLI, not shell.
  # shellcheck disable=SC2016
  aws route53 list-hosted-zones --query \
    'HostedZones[?Config.PrivateZone==`false`].Name | [0]' --output text 2>/dev/null \
    | sed 's/\.$//'
}

# ---- cluster access -------------------------------------------------------
# The clusters do not exist when the ops box is created, so its access entry
# cannot be made in Terraform. It is made here, on first use, for the box's own
# role. This is the box granting itself the access it needs to operate, not a
# hand-fix to make a check pass.
ensure_cluster_access() {
  cluster="$1"
  acct="$(account_id)" || return 1
  [ -n "$acct" ] || return 1
  principal="arn:aws:iam::${acct}:role/${OPSBOX_ROLE_NAME}"

  aws eks describe-cluster --name "$cluster" >/dev/null 2>&1 || return 1

  if ! aws eks describe-access-entry --cluster-name "$cluster" \
        --principal-arn "$principal" >/dev/null 2>&1; then
    aws eks create-access-entry --cluster-name "$cluster" \
      --principal-arn "$principal" >/dev/null 2>&1 || true
  fi
  aws eks associate-access-policy --cluster-name "$cluster" \
    --principal-arn "$principal" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster >/dev/null 2>&1 || true

  aws eks update-kubeconfig --name "$cluster" >/dev/null 2>&1 || return 1
  kubectl --context "$(kubectl config current-context)" version >/dev/null 2>&1 || true
  return 0
}

# kc <cluster> <kubectl args...> — run kubectl against a named cluster.
kc() {
  cluster="$1"; shift
  aws eks update-kubeconfig --name "$cluster" >/dev/null 2>&1 || return 1
  kubectl "$@"
}

# ---- Terraform phases ------------------------------------------------------
# A phase's apply is FINISHED when its remote state has been written and nobody
# holds its lock any more. This exists because the "things the phase creates"
# checks below go true too early: on build #9 the wildcard certificate was
# ISSUED and the user pool existed about two minutes before base's apply had
# finished the VPC, so a check on those alone told the operator to start
# management against a base whose state was still being written.
#
# The S3 backend writes the state object and holds a DynamoDB item whose LockID
# is "<bucket>/<key>" for exactly the duration of an apply (the "<key>-md5"
# digest item persists and is not a lock). Both are read-only reads against the
# account: ask the world, not the workflow.
STATE_TABLE="${STATE_TABLE:-k8-platform-tfstate-lock}"

state_settled() {
  phase="$1"
  acct="$(account_id)"; [ -n "$acct" ] || return 1
  bucket="k8-platform-tfstate-${acct}"
  key="k8-platform/${phase}/terraform.tfstate"
  n="$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$key" \
       --query "length(Contents[?Key=='${key}'] || \`[]\`)" --output text 2>/dev/null)"
  [ "${n:-0}" -ge 1 ] 2>/dev/null || return 1
  # Fail closed: if the lock cannot be READ (IAM, API error), the phase is not
  # known to be settled. An unreadable lock must never read as a free one.
  lock="$(aws dynamodb get-item --table-name "$STATE_TABLE" \
          --key "{\"LockID\":{\"S\":\"${bucket}/${key}\"}}" \
          --query 'Item.LockID.S' --output text 2>/dev/null)" || return 1
  case "$lock" in ""|None) return 0 ;; *) return 1 ;; esac
}

# ---- stage checks ---------------------------------------------------------
# Each returns 0 when the stage is genuinely true of the world.

check_credentials() { [ -n "$(account_id)" ]; }

check_zone() { [ -n "$(platform_domain)" ]; }

# Base is applied when the things base creates exist: the wildcard certificate
# is ISSUED and the Cognito user pool is there. These are exactly the
# assertions the workflow's own `[base] e2e-verify` step makes. AND its apply
# has finished: both exist early in the apply (build #9), so on their own they
# would send the operator to management too soon.
check_base() {
  state_settled base || return 1
  dom="$(platform_domain)"; [ -n "$dom" ] || return 1
  st="$(aws acm list-certificates \
        --query "CertificateSummaryList[?DomainName=='*.${dom}'].Status | [0]" \
        --output text 2>/dev/null)"
  [ "$st" = "ISSUED" ] || return 1
  pools="$(aws cognito-idp list-user-pools --max-results 50 \
           --query "length(UserPools[?Name=='k8-platform-users'])" --output text 2>/dev/null)"
  [ "${pools:-0}" -ge 1 ] 2>/dev/null
}

# Management is applied when the hub cluster is ACTIVE with a live node group
# AND Argo CD's bootstrap Application exists — the cluster alone is not enough,
# because the Helm releases land minutes later.
check_management() {
  state_settled management || return 1
  [ "$(aws eks describe-cluster --name "$HUB_CLUSTER" \
        --query 'cluster.status' --output text 2>/dev/null)" = "ACTIVE" ] || return 1
  ng="$(aws eks list-nodegroups --cluster-name "$HUB_CLUSTER" \
        --query 'nodegroups | [0]' --output text 2>/dev/null)"
  [ -n "$ng" ] && [ "$ng" != "None" ] || return 1
  [ "$(aws eks describe-nodegroup --cluster-name "$HUB_CLUSTER" --nodegroup-name "$ng" \
        --query 'nodegroup.status' --output text 2>/dev/null)" = "ACTIVE" ] || return 1
  ensure_cluster_access "$HUB_CLUSTER" >/dev/null 2>&1 || return 1
  kc "$HUB_CLUSTER" -n argocd get application bootstrap >/dev/null 2>&1
}

# The transient Applications settle about eight minutes after management. Gate
# 1 must not be synced before the XRDs and Compositions are in place.
check_crossplane_resources() {
  s="$(kc "$HUB_CLUSTER" -n argocd get application crossplane-resources \
       -o jsonpath='{.status.sync.status}{" "}{.status.health.status}' 2>/dev/null)"
  [ "$s" = "Synced Healthy" ]
}

# A gate is confirmed by its COMPLETED OPERATION, never by .status.sync.revision
# — Argo sets that field from the target revision it has observed, so it reads
# correct for a gate that has never synced (kp-2al.24).
gate_synced_at() {
  app="$1"; sha="$2"
  out="$(kc "$HUB_CLUSTER" -n argocd get application "$app" \
    -o jsonpath='{.status.operationState.phase}{" "}{.status.operationState.syncResult.revision}{" "}{.status.sync.status}' 2>/dev/null)"
  case "$out" in
    "Succeeded $sha Synced") return 0 ;;
    *) return 1 ;;
  esac
}

# Gate 1 is done when the composite has published all four facts AND the spoke
# node group is Ready. Not when the XR reports Ready — its timing is not part
# of the contract and either ordering is fine (kp-2al.23).
check_gate1() {
  facts="$(kc "$HUB_CLUSTER" -n platform get xplatformcluster platform \
    -o jsonpath='{.status.oidcIssuer}|{.status.endpoint}|{.status.clusterCaData}|{.status.certificateArn}' 2>/dev/null)"
  case "$facts" in
    ""|*"||"*|"|"*|*"|") return 1 ;;
  esac
  ready="$(kc "$HUB_CLUSTER" get nodegroups.eks.aws.m.upbound.io -A \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [ "$ready" = "True" ]
}

check_gate2() {
  [ "$(kc "$HUB_CLUSTER" -n platform get xspokeaccess platform \
       -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

# Converged means every Application is Synced/Healthy except workload1-cluster,
# which is OutOfSync by design (the unpulled second-cluster gate).
check_converged() {
  out="$(kc "$HUB_CLUSTER" -n argocd get applications --no-headers 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  total="$(printf '%s\n' "$out" | grep -c .)"
  [ "$total" -ge 17 ] || return 1
  bad="$(printf '%s\n' "$out" | grep -v '^workload1-cluster ' \
         | awk '$2!="Synced" || $3!="Healthy"' | grep -c .)"
  [ "$bad" -eq 0 ]
}

# The behavioural gate. This is THE check — a real request over the public
# internet to the demo app on the spoke.
#
# The hostname is resolved from Route53 itself, not through the box's resolver.
# The VPC resolver caches a NEGATIVE answer for the zone's SOA minimum (900 s
# on Route53), and this check necessarily asks for hello.platform BEFORE
# ExternalDNS has written it — so on build #9 the box could not see a record
# that existed, and had answered 200 from elsewhere, for a quarter of an hour;
# the driver's 600 s endpoint budget ran out on a working platform. Reading
# the record from the authority and pinning the connection to its target
# (`--resolve`) keeps the request honest: same hostname, same SNI, same
# certificate validation, no dependence on what a cache remembers.
endpoint_target_ip() {
  host="$1"
  # shellcheck disable=SC2016
  zone="$(aws route53 list-hosted-zones \
    --query 'HostedZones[?Config.PrivateZone==`false`].Id | [0]' --output text 2>/dev/null)"
  [ -n "$zone" ] && [ "$zone" != "None" ] || return 1
  rec="$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" \
    --query "ResourceRecordSets[?Name=='${host}.' && Type=='A'] | [0].[AliasTarget.DNSName, ResourceRecords[0].Value]" \
    --output text 2>/dev/null)"
  alias="$(printf '%s' "$rec" | cut -f1)"; plain="$(printf '%s' "$rec" | cut -f2)"
  if [ -n "$alias" ] && [ "$alias" != "None" ]; then
    # An alias to a load balancer: its own name resolves (it existed from the
    # moment the balancer did, so it was never negatively cached).
    getent ahostsv4 "${alias%.}" 2>/dev/null | awk 'NR==1 {print $1}'
  elif [ -n "$plain" ] && [ "$plain" != "None" ]; then
    printf '%s\n' "$plain"
  else
    return 1
  fi
}

check_endpoint() {
  dom="$(platform_domain)"; [ -n "$dom" ] || return 1
  host="hello.platform.${dom}"
  ip="$(endpoint_target_ip "$host")"; [ -n "$ip" ] || return 1
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 \
          --resolve "${host}:443:${ip}" "https://${host}/" 2>/dev/null)"
  [ "$code" = "200" ]
}

# wait_for <check-fn> <label> <timeout-seconds> [interval]
# Polls a check, printing progress, until it passes or the budget runs out.
wait_for() {
  fn="$1"; label="$2"; budget="$3"; interval="${4:-30}"
  start="$(date +%s)"
  while :; do
    if "$fn"; then
      printf '\n'; green "$label (after $(( $(date +%s) - start ))s)"
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$budget" ]; then
      printf '\n'; red "$label — still not true after ${elapsed}s"
      return 1
    fi
    printf '\r%sWAITING%s  %s  %ss elapsed, budget %ss ' \
      "$C_YELLOW" "$C_OFF" "$label" "$elapsed" "$budget"
    sleep "$interval"
  done
}
