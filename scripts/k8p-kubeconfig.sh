#!/usr/bin/env bash
# k8p-kubeconfig.sh — add kubectl contexts for the platform's EKS clusters and
# prove each API answers (kp-2al.42).
#
# For every platform cluster in the current AWS account/region it runs
# `aws eks update-kubeconfig` with a context named after the cluster, then a
# few read-only connectivity tests and a PASS/FAIL line for each:
#
#   API /readyz        the API server answers at all            (FAIL if not)
#   nodes              `get nodes` works; Ready count reported  (FAIL if not)
#   can-i              list pods -A, create namespaces          (reported only)
#   identity           `auth whoami`                            (reported only)
#
# Exit 0 when every platform cluster found is reachable and its nodes can be
# read; 1 when any is not (or there are no AWS credentials); 2 on bad usage.
# Finding zero platform clusters is not a failure: it is said explicitly.
#
# Which clusters count as the platform's, in order:
#   1. tag Project=k8-platform           (the hub: terraform/management default_tags)
#   2. tag PlatformAbstraction=PlatformCluster
#                                        (spokes: crossplane/compositions/platform-cluster.yaml)
#   3. name prefix k8-platform-          (fallback when tags are absent or unreadable)
# The script prints which rule recognised each cluster.
#
# Access model (why `can-i` differs by cluster, and why "no" is not a failure):
#   hub   — the IAM principal that created it is cluster-admin; the ops box's
#           role becomes admin once k8p-bringup.sh / k8p-status.sh has run.
#   spoke — cloud_user has a read-only AmazonEKSAdminViewPolicy access entry
#           (the Composition's sandbox-access-entry). The ops box role has
#           none, so from the ops box a spoke reports UNAUTHORIZED.
# Cluster API endpoints are public: no VPN or relay is needed.
#
# Read-only against AWS and the clusters. It writes only kubeconfig entries
# (to ~/.kube/config, or --kubeconfig PATH). It never prints tokens or keys.
#
# USAGE
#   k8p-kubeconfig.sh [-r REGION] [--kubeconfig PATH] [--only CLUSTER] [--no-tests]
set -uo pipefail
: "${AWS_PAGER:=}"; export AWS_PAGER

PREFIX="k8-platform-"
REGION=""
KUBECONFIG_PATH=""
ONLY=""
RUN_TESTS=1

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--region)  [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; REGION="$2"; shift 2 ;;
    --kubeconfig) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; KUBECONFIG_PATH="$2"; shift 2 ;;
    --only)       [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; ONLY="$2"; shift 2 ;;
    --no-tests)   RUN_TESTS=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_DIM=""; C_OFF=""
fi
pass() { printf '%sPASS%s  %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() { printf '%sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$1"; }
info() { printf '%sINFO%s  %s\n' "$C_DIM" "$C_OFF" "$1"; }
head_() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }

# Anything relayed from a tool's error output passes through here first, so an
# EKS bearer token or an access key id in an error message is never printed.
redact() {
  sed -E \
    -e 's/k8s-aws-v1\.[A-Za-z0-9_.=-]+/<redacted-token>/g' \
    -e 's/(A3T[A-Z0-9]|AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}/<redacted-key-id>/g' \
    -e 's/([Bb]earer|[Tt]oken|[Ss]ecret|[Pp]assword)([=: ]+)[^ ]+/\1\2<redacted>/g'
}
first_line() { redact | grep -m1 . | cut -c1-200; }

for bin in aws kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { fail "'$bin' not found on PATH"; exit 1; }
done

if [ -z "$REGION" ]; then
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  [ -n "$REGION" ] || REGION="$(aws configure get region 2>/dev/null || true)"
  [ -n "$REGION" ] || REGION="us-east-1"
fi

KC=(kubectl)
UKC=()
if [ -n "$KUBECONFIG_PATH" ]; then
  KC=(kubectl --kubeconfig "$KUBECONFIG_PATH")
  UKC=(--kubeconfig "$KUBECONFIG_PATH")
fi

head_ "PLATFORM KUBECONFIG  $(date -u +%FT%TZ)"
ident="$(aws sts get-caller-identity --region "$REGION" --query '[Account,Arn]' --output text 2>&1)"
rc=$?
ACCOUNT="$(printf '%s' "$ident" | cut -f1)"
CALLER="$(printf '%s' "$ident" | cut -f2)"
if [ "$rc" -ne 0 ] || [ -z "$ACCOUNT" ] || [ -z "$CALLER" ]; then
  fail "no AWS identity: $(printf '%s\n' "$ident" | first_line)"
  printf '\nRESULT: FAIL  cannot discover clusters without AWS credentials\n'
  exit 1
fi
info "account $ACCOUNT   region $REGION"
info "AWS identity $CALLER"
info "kubeconfig ${KUBECONFIG_PATH:-${KUBECONFIG:-~/.kube/config}}"

# ---- discovery --------------------------------------------------------------
head_ "Discovery (aws eks list-clusters in $ACCOUNT/$REGION)"
if ! listed="$(aws eks list-clusters --region "$REGION" --query clusters --output text 2>&1)"; then
  fail "aws eks list-clusters failed: $(printf '%s\n' "$listed" | first_line)"
  printf '\nRESULT: FAIL  cannot list clusters in %s/%s\n' "$ACCOUNT" "$REGION"
  exit 1
fi
ALL=()
for c in $(printf '%s' "$listed" | tr '\t\n' '  '); do
  [ "$c" = "None" ] || ALL+=("$c")
done

if [ -n "$ONLY" ]; then
  found=0
  for c in "${ALL[@]}"; do [ "$c" = "$ONLY" ] && found=1; done
  if [ "$found" -eq 0 ]; then
    fail "--only $ONLY: $ONLY not found in $ACCOUNT/$REGION (clusters there: ${ALL[*]:-none})"
    printf '\nRESULT: FAIL  requested cluster does not exist\n'
    exit 1
  fi
  ALL=("$ONLY")
fi

CLUSTERS=(); ROLES=(); STATUSES=()
for c in "${ALL[@]}"; do
  d="$(aws eks describe-cluster --name "$c" --region "$REGION" \
        --query 'cluster.[tags.Project,tags.PlatformAbstraction,status]' --output text 2>/dev/null)"
  project="$(printf '%s' "$d" | cut -f1)"
  abstraction="$(printf '%s' "$d" | cut -f2)"
  status="$(printf '%s' "$d" | cut -f3)"
  how=""; role=""
  if [ "$project" = "k8-platform" ]; then
    role="hub"; how="tag Project=k8-platform"
  elif [ "$abstraction" = "PlatformCluster" ]; then
    role="spoke"; how="tag PlatformAbstraction=PlatformCluster"
  elif [ "${c#"$PREFIX"}" != "$c" ]; then
    role="unknown role"; how="name prefix ${PREFIX} (no platform tags)"
  elif [ -n "$ONLY" ]; then
    role="unknown role"; how="--only (not recognised as a platform cluster)"
  fi
  if [ -z "$how" ]; then
    info "skipped $c: no platform tag and no ${PREFIX} name prefix"
    continue
  fi
  printf '  found %s  (%s; recognised by %s)\n' "$c" "$role" "$how"
  CLUSTERS+=("$c"); ROLES+=("$role"); STATUSES+=("${status:-UNKNOWN}")
done

if [ "${#CLUSTERS[@]}" -eq 0 ]; then
  printf '\nno platform clusters found in %s/%s (searched %d cluster(s): %s)\n' \
    "$ACCOUNT" "$REGION" "${#ALL[@]}" "${ALL[*]:-none}"
  printf 'RESULT: NONE  nothing to connect or test\n'
  exit 0
fi

# ---- per cluster ------------------------------------------------------------
OK=0; FAILING=(); SUMMARY=()
for i in "${!CLUSTERS[@]}"; do
  c="${CLUSTERS[$i]}"; role="${ROLES[$i]}"; status="${STATUSES[$i]}"
  head_ "$c ($role)"
  case "$role" in
    hub)   info "$c: expected access: the hub's creator is cluster-admin; the ops box role is admin after k8p-bringup.sh" ;;
    spoke) info "$c: expected access: cloud_user is read-only (AmazonEKSAdminViewPolicy); the ops box role has no entry" ;;
  esac

  if [ "$status" != "ACTIVE" ]; then
    fail "$c: cluster status is $status, not ACTIVE"
    FAILING+=("$c"); SUMMARY+=("$c  NOT ACTIVE ($status)"); continue
  fi

  if ! out="$(aws eks update-kubeconfig --name "$c" --region "$REGION" --alias "$c" "${UKC[@]}" 2>&1)"; then
    fail "$c: aws eks update-kubeconfig failed: $(printf '%s\n' "$out" | first_line)"
    FAILING+=("$c"); SUMMARY+=("$c  NO CONTEXT"); continue
  fi
  pass "$c: kubectl context '$c' written"

  if [ "$RUN_TESTS" -eq 0 ]; then
    info "$c: connectivity tests skipped (--no-tests)"
    OK=$((OK + 1)); SUMMARY+=("$c  context written, not tested"); continue
  fi

  k=("${KC[@]}" --context "$c" --request-timeout=20s)

  if out="$("${k[@]}" get --raw /readyz 2>&1)" && [ "$out" = "ok" ]; then
    pass "$c: API /readyz answered ok"
  else
    case "$out" in
      *Unauthorized*|*"provide credentials"*|*Forbidden*|*forbidden*)
        fail "$c: API reachable but this identity is not authorized (UNAUTHORIZED)"
        info "$c: $CALLER needs an EKS access entry on $c"
        FAILING+=("$c"); SUMMARY+=("$c  UNAUTHORIZED") ;;
      *)
        fail "$c: API /readyz did not answer (UNREACHABLE)"
        info "$c: $(printf '%s\n' "$out" | first_line)"
        FAILING+=("$c"); SUMMARY+=("$c  UNREACHABLE") ;;
    esac
    continue
  fi

  if ! out="$("${k[@]}" get nodes --no-headers 2>&1)"; then
    fail "$c: cannot read nodes: $(printf '%s\n' "$out" | first_line)"
    FAILING+=("$c"); SUMMARY+=("$c  NODES UNREADABLE"); continue
  fi
  total="$(printf '%s\n' "$out" | grep -c .)"
  ready="$(printf '%s\n' "$out" | awk '$2=="Ready"' | grep -c .)"
  pass "$c: nodes readable, ${ready}/${total} Ready"
  [ "$ready" -gt 0 ] || info "$c: no Ready nodes (the API answers; workloads cannot schedule)"

  for q in "list pods -A" "create namespaces"; do
    # shellcheck disable=SC2086  # $q is a fixed, intended word list
    a="$("${k[@]}" auth can-i $q 2>/dev/null | head -n1)"
    info "$c: can-i ${q}: ${a:-unknown}"
  done

  who="$("${k[@]}" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null | redact)"
  info "$c: kubernetes identity ${who:-unavailable (kubectl auth whoami not supported)}"

  OK=$((OK + 1)); SUMMARY+=("$c  REACHABLE  nodes ${ready}/${total} Ready  identity ${who:-unknown}")
done

# ---- summary ----------------------------------------------------------------
head_ "Summary ($ACCOUNT/$REGION)"
for s in "${SUMMARY[@]}"; do printf '  %s\n' "$s"; done
cur="$("${KC[@]}" config current-context 2>/dev/null)"
[ -n "$cur" ] && info "current-context is now $cur (use --context <cluster> to pick one)"
printf '\n'
n="${#CLUSTERS[@]}"
if [ "${#FAILING[@]}" -eq 0 ]; then
  printf 'RESULT: PASS  %d/%d platform clusters reachable\n' "$OK" "$n"
  exit 0
fi
printf 'RESULT: FAIL  %d/%d platform clusters reachable; failing: %s\n' "$OK" "$n" "${FAILING[*]}"
exit 1
