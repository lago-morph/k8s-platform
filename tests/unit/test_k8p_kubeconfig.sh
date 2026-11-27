#!/usr/bin/env bash
# kp-2al.42 — scripts/k8p-kubeconfig.sh: the installer's "connect kubectl to
# the clusters and prove the API answers" script.
#
# The script decides, on an installer's behalf, whether each cluster is
# reachable. Wrong in the optimistic direction (an unreachable cluster reported
# as fine, or exit 0) is the failure that matters, so the scenarios below drive
# it against a MOCKED world and assert it says "no" when the world says no.
#
# Strategy mirrors tests/unit/test_opsbox_bringup.sh: shim `aws` and `kubectl`
# onto PATH and describe the fake world with environment variables. No AWS,
# no cluster, no network.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

SCRIPT="scripts/k8p-kubeconfig.sh"
MOCK_DIR="$(mktemp -d -t k8p-kubeconfig-mock-XXXXXX)"
trap 'rm -rf "$MOCK_DIR"' EXIT

# Sentinels: values shaped like real credentials. None may ever reach output.
FAKE_SECRET="wJalrXUtnFEMI/K7MDENG/bPxRfiCYSENTINELKEY"
FAKE_SESSION="FwoGZXIvYXdzSENTINELSESSIONTOKENzzzzzzzzzz"
FAKE_KEYID="ASIAZZZZSENTINEL0001"
FAKE_BEARER="k8s-aws-v1.aHR0cHM6Ly9zdHMuYW1hem9uYXdzLmNvbS9TRU5USU5FTA"

# ---------------------------------------------------------------------------
# Shims
# ---------------------------------------------------------------------------
cat > "$MOCK_DIR/aws" <<'SHIM'
#!/usr/bin/env bash
set -u
echo "aws $*" >> "${MOCK_LOG:-/dev/null}"
svc="${1:-}"; op="${2:-}"
arg_after() { flag="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$flag" ] && { printf '%s' "${2:-}"; return; }; shift; done; }
case "$svc $op" in
  "sts get-caller-identity")
    [ "${MOCK_NO_CREDS:-0}" = 1 ] && { echo "Unable to locate credentials" >&2; exit 255; }
    printf '%s\t%s\n' "123456789012" "arn:aws:iam::123456789012:user/cloud_user" ;;
  "configure get") printf '%s\n' "${MOCK_CONFIG_REGION:-}" ;;
  "eks list-clusters")
    # text output of `--query clusters`: tab-separated names, or empty
    printf '%s\n' "${MOCK_CLUSTERS:-}" ;;
  "eks describe-cluster")
    name="$(arg_after --name "$@")"
    # fields: Project tag, PlatformAbstraction tag, status
    case "$name" in
      k8-platform-mgmt)     printf 'k8-platform\tNone\tACTIVE\n' ;;
      k8-platform-services) printf 'None\tPlatformCluster\t%s\n' "${MOCK_SPOKE_STATUS:-ACTIVE}" ;;
      k8-platform-untagged) printf 'None\tNone\tACTIVE\n' ;;
      *)                    printf 'None\tNone\tACTIVE\n' ;;
    esac ;;
  "eks update-kubeconfig")
    # The real CLI prints an ARN; a hostile/verbose one might print more.
    # The script must not relay any of it.
    echo "Added new context $(arg_after --alias "$@") to kubeconfig token=$FAKE_BEARER" ;;
  *) exit 0 ;;
esac
SHIM

cat > "$MOCK_DIR/kubectl" <<'SHIM'
#!/usr/bin/env bash
set -u
echo "kubectl $*" >> "${MOCK_LOG:-/dev/null}"
ctx=""; prev=""
for a in "$@"; do [ "$prev" = "--context" ] && ctx="$a"; prev="$a"; done
all=" $* "
case " ${MOCK_UNREACHABLE:-} " in
  *" $ctx "*)
    echo "Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout (Authorization: Bearer $FAKE_BEARER key=$FAKE_KEYID)" >&2
    exit 1 ;;
esac
case " ${MOCK_UNAUTHORIZED:-} " in
  *" $ctx "*)
    case "$all" in *" config "*) : ;; *)
      echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1 ;;
    esac ;;
esac
case "$all" in
  *" get --raw /readyz "*) printf 'ok' ;;
  *" get nodes "*)
    case "$ctx" in
      k8-platform-mgmt) printf 'ip-1 Ready <none> 1d v1.33\nip-2 Ready <none> 1d v1.33\n' ;;
      *)                printf 'ip-3 Ready <none> 1d v1.33\nip-4 NotReady <none> 1d v1.33\nip-5 Ready <none> 1d v1.33\n' ;;
    esac ;;
  *" auth can-i list pods "*)
    echo yes ;;
  *" auth can-i create namespaces "*)
    case "$ctx" in k8-platform-mgmt) echo yes ;; *) echo no; exit 1 ;; esac ;;
  *" auth whoami "*)
    case "$ctx" in
      k8-platform-mgmt) printf 'arn:aws:iam::123456789012:user/cloud_user' ;;
      *)                printf 'arn:aws:iam::123456789012:user/cloud_user' ;;
    esac ;;
  *" config current-context "*) echo "${MOCK_LAST_CTX:-k8-platform-services}" ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$MOCK_DIR/aws" "$MOCK_DIR/kubectl"

# run <args...> — run the script in the mocked world; sets OUT and RC.
run() {
  MOCK_LOG="$MOCK_DIR/calls.log"; : > "$MOCK_LOG"
  OUT="$(PATH="$MOCK_DIR:$PATH" MOCK_LOG="$MOCK_LOG" \
         FAKE_BEARER="$FAKE_BEARER" FAKE_KEYID="$FAKE_KEYID" \
         AWS_ACCESS_KEY_ID="ASIAZZZZSENTINEL0001" AWS_SECRET_ACCESS_KEY="$FAKE_SECRET" \
         AWS_SESSION_TOKEN="$FAKE_SESSION" AWS_REGION="" AWS_DEFAULT_REGION="" \
         NO_COLOR=1 bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

no_credentials_in_output() {
  label="$1"
  leaked=""
  for v in "$FAKE_SECRET" "$FAKE_SESSION" "$FAKE_KEYID" "$FAKE_BEARER" "k8s-aws-v1."; do
    case "$OUT" in *"$v"*) leaked="$leaked $v" ;; esac
  done
  if [ -z "$leaked" ]; then _pass "$label: no credential-looking value printed"
  else _fail "$label: no credential-looking value printed" "leaked:$leaked"; fi
}

[ -f "$SCRIPT" ] && _pass "script exists at $SCRIPT" || _fail "script exists at $SCRIPT"

# ---------------------------------------------------------------------------
echo "── zero clusters ──"
MOCK_CLUSTERS="" run
assert_eq "zero clusters: exit 0 (nothing unreachable)" "0" "$RC"
assert_contains "zero clusters: says so explicitly" \
  "no platform clusters found in 123456789012/us-east-1" "$OUT"
# A non-platform cluster alone is still zero platform clusters.
MOCK_CLUSTERS="someone-elses-cluster" run
assert_contains "foreign cluster only: still none found" \
  "no platform clusters found in 123456789012/us-east-1" "$OUT"
assert_contains "foreign cluster only: names what it skipped" "someone-elses-cluster" "$OUT"
case "$(cat "$MOCK_DIR/calls.log")" in
  *"update-kubeconfig"*) _fail "foreign cluster: kubeconfig left untouched" ;;
  *)                     _pass "foreign cluster: kubeconfig left untouched" ;;
esac

# ---------------------------------------------------------------------------
echo "── two healthy clusters ──"
MOCK_CLUSTERS=$'k8-platform-mgmt\tk8-platform-services\tsomeone-elses-cluster' run
assert_eq "healthy: exit 0" "0" "$RC"
assert_contains "healthy: hub recognised by tag" "k8-platform-mgmt  (hub; recognised by tag Project=k8-platform)" "$OUT"
assert_contains "healthy: spoke recognised by tag" "k8-platform-services  (spoke; recognised by tag PlatformAbstraction=PlatformCluster)" "$OUT"
assert_contains "healthy: readyz PASS on hub" "PASS  k8-platform-mgmt: API /readyz answered ok" "$OUT"
assert_contains "healthy: node count on hub" "PASS  k8-platform-mgmt: nodes readable, 2/2 Ready" "$OUT"
assert_contains "healthy: node count on spoke" "PASS  k8-platform-services: nodes readable, 2/3 Ready" "$OUT"
assert_contains "healthy: whoami printed" "identity arn:aws:iam::123456789012:user/cloud_user" "$OUT"
assert_contains "healthy: can-i no is reported, not failed" \
  "INFO  k8-platform-services: can-i create namespaces: no" "$OUT"
assert_contains "healthy: summary" "RESULT: PASS  2/2 platform clusters reachable" "$OUT"
case "$OUT" in *"FAIL  "*) _fail "healthy: no FAIL lines" "$(printf '%s\n' "$OUT" | grep 'FAIL  ')";;
               *) _pass "healthy: no FAIL lines" ;; esac
grep -q -- "update-kubeconfig --name k8-platform-mgmt --region us-east-1 --alias k8-platform-mgmt" "$MOCK_DIR/calls.log" \
  && _pass "healthy: context aliased to the cluster name" \
  || _fail "healthy: context aliased to the cluster name" "$(grep update-kubeconfig "$MOCK_DIR/calls.log")"
grep -q "someone-elses-cluster" <(grep update-kubeconfig "$MOCK_DIR/calls.log") \
  && _fail "healthy: foreign cluster not added" || _pass "healthy: foreign cluster not added"
no_credentials_in_output "healthy"

# ---------------------------------------------------------------------------
echo "── one unreachable cluster ──"
MOCK_CLUSTERS=$'k8-platform-mgmt\tk8-platform-services' MOCK_UNREACHABLE="k8-platform-services" run
[ "$RC" -ne 0 ] && _pass "unreachable: exit non-zero" || _fail "unreachable: exit non-zero" "rc=$RC"
assert_contains "unreachable: clear FAIL line" \
  "FAIL  k8-platform-services: API /readyz did not answer (UNREACHABLE)" "$OUT"
assert_contains "unreachable: the other cluster still tested" \
  "PASS  k8-platform-mgmt: nodes readable, 2/2 Ready" "$OUT"
assert_contains "unreachable: summary names it" \
  "RESULT: FAIL  1/2 platform clusters reachable; failing: k8-platform-services" "$OUT"
no_credentials_in_output "unreachable (error text carried a token)"

# ---------------------------------------------------------------------------
echo "── reachable but not authorized ──"
MOCK_CLUSTERS=$'k8-platform-mgmt\tk8-platform-services' MOCK_UNAUTHORIZED="k8-platform-services" run
[ "$RC" -ne 0 ] && _pass "unauthorized: exit non-zero" || _fail "unauthorized: exit non-zero" "rc=$RC"
assert_contains "unauthorized: distinguished from unreachable" \
  "FAIL  k8-platform-services: API reachable but this identity is not authorized (UNAUTHORIZED)" "$OUT"

# ---------------------------------------------------------------------------
echo "── options ──"
MOCK_CLUSTERS=$'k8-platform-mgmt\tk8-platform-services' run --only k8-platform-mgmt -r eu-west-1 --kubeconfig "$MOCK_DIR/kc"
assert_eq "--only: exit 0" "0" "$RC"
assert_contains "--only: summary counts one" "RESULT: PASS  1/1 platform clusters reachable" "$OUT"
grep -q "k8-platform-services" <(grep update-kubeconfig "$MOCK_DIR/calls.log") \
  && _fail "--only: other cluster not touched" || _pass "--only: other cluster not touched"
grep -q -- "--region eu-west-1" "$MOCK_DIR/calls.log" && _pass "-r: region passed through" || _fail "-r: region passed through"
grep -q -- "update-kubeconfig .*--kubeconfig $MOCK_DIR/kc" "$MOCK_DIR/calls.log" \
  && _pass "--kubeconfig: passed to update-kubeconfig" || _fail "--kubeconfig: passed to update-kubeconfig"
grep -q -- "kubectl --kubeconfig $MOCK_DIR/kc" "$MOCK_DIR/calls.log" \
  && _pass "--kubeconfig: passed to kubectl" || _fail "--kubeconfig: passed to kubectl"

MOCK_CLUSTERS=$'k8-platform-mgmt' run --only k8-platform-nope
[ "$RC" -ne 0 ] && _pass "--only missing cluster: exit non-zero" || _fail "--only missing cluster: exit non-zero"
assert_contains "--only missing cluster: says so" "k8-platform-nope not found in 123456789012/us-east-1" "$OUT"

MOCK_CLUSTERS=$'k8-platform-mgmt\tk8-platform-services' run --no-tests
assert_eq "--no-tests: exit 0" "0" "$RC"
case "$(cat "$MOCK_DIR/calls.log")" in
  *"get --raw"*|*"get nodes"*) _fail "--no-tests: no API calls made" ;;
  *) _pass "--no-tests: no API calls made" ;;
esac
assert_contains "--no-tests: says tests skipped" "connectivity tests skipped (--no-tests)" "$OUT"

MOCK_CLUSTERS=$'k8-platform-untagged' run
assert_contains "untagged: prefix fallback is named" \
  "k8-platform-untagged  (unknown role; recognised by name prefix k8-platform- (no platform tags))" "$OUT"

MOCK_CLUSTERS=$'k8-platform-mgmt\tk8-platform-services' MOCK_SPOKE_STATUS=CREATING run
[ "$RC" -ne 0 ] && _pass "non-ACTIVE cluster: exit non-zero" || _fail "non-ACTIVE cluster: exit non-zero"
assert_contains "non-ACTIVE cluster: FAIL line" "FAIL  k8-platform-services: cluster status is CREATING, not ACTIVE" "$OUT"

MOCK_CONFIG_REGION="ap-south-1" MOCK_CLUSTERS="" run
assert_contains "region falls back to aws config" "123456789012/ap-south-1" "$OUT"

MOCK_NO_CREDS=1 run
[ "$RC" -ne 0 ] && _pass "no credentials: exit non-zero" || _fail "no credentials: exit non-zero"
assert_contains "no credentials: says so" "FAIL  no AWS identity" "$OUT"
no_credentials_in_output "no credentials"

run --bogus
assert_eq "unknown option: exit 2" "2" "$RC"

# ---------------------------------------------------------------------------
echo "── on the ops box PATH ──"
# The ops box puts scripts/opsbox on PATH (terraform/opsbox/user_data.sh.tftpl).
if [ -x scripts/opsbox/k8p-kubeconfig.sh ] && \
   [ "$(readlink -f scripts/opsbox/k8p-kubeconfig.sh)" = "$(readlink -f "$SCRIPT")" ]; then
  _pass "scripts/opsbox/k8p-kubeconfig.sh resolves to $SCRIPT"
else
  _fail "scripts/opsbox/k8p-kubeconfig.sh resolves to $SCRIPT"
fi
grep -q 'scripts/opsbox:' terraform/opsbox/user_data.sh.tftpl \
  && _pass "ops box PATH still carries scripts/opsbox" || _fail "ops box PATH still carries scripts/opsbox"

assert_summary
