#!/usr/bin/env bash
# kp-2al.52 — hermetic unit test for the live check
#   tests/live/checks/after/argocd-admin-password-live.sh
#
# The claim the check attests: the Argo CD admin password stored in ASM
# (k8-platform/management/argocd-admin, AWSCURRENT) logs in to the hub's
# Argo CD right now. This test drives the check with stub `aws` and `curl` on
# PATH and the REAL scripts/k8p-argocd-password.sh (the check delegates the
# login to its `check` command), in a fake REPO_ROOT. No AWS, no network.
#
# Asserted:
#   (a) STATIC: line 2 declares `# live-identity: cluster` (the scoped verifier
#       role may only read live-verify/* secret values); no COVERS line; the
#       login is the password script's `check`; no literal domain.
#   (b) ASM value accepted by Argo CD        => PASS (0)
#   (c) ASM value refused by Argo CD         => FAIL (1), not a skip
#   (d) ASM secret missing while hub exists  => FAIL (1), not a skip
#   (e) no public hosted zone                => SKIP (2)
#   (f) no hub cluster                       => SKIP (2)
#   (g) in every case the password appears in NO output and NO argv.
# shellcheck disable=SC2016  # literal $-strings: a password with shell metacharacters, and source text to match
set -uo pipefail
REAL_REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REAL_REPO_ROOT" || exit 1
# shellcheck disable=SC1091
. tests/lib/assert.sh

CHECK_SRC="tests/live/checks/after/argocd-admin-password-live.sh"
SECRET="k8-platform/management/argocd-admin"
PW='S3cret pw "quoted" $dollar!'

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---- (a) static ------------------------------------------------------------
echo "── argocd-admin-password-live: static ───────────────────────────────"
[ -f "$CHECK_SRC" ] || { _fail "check present" "missing $CHECK_SRC"; assert_summary; exit 1; }
SRC="$(cat "$CHECK_SRC")"
assert_eq "line 2 declares the cluster identity" "# live-identity: cluster" \
  "$(sed -n 2p "$CHECK_SRC" | awk '{print $1, $2, $3}')"
assert_eq "emits no COVERS line (no declared kind maps to a login)" "" \
  "$(printf '%s\n' "$SRC" | grep -vE '^[[:space:]]*#' | grep -E '(^|[[:space:]])covers[[:space:]]' || true)"
assert_contains "the password script is the login path" 'PW_SCRIPT="$REPO_ROOT/scripts/k8p-argocd-password.sh"' "$SRC"
assert_contains "logs in through its check command" 'bash "$PW_SCRIPT" check' "$SRC"
assert_contains "the host is derived from the public hosted zone" "list-hosted-zones" "$SRC"
assert_eq "no literal domain" "" \
  "$(printf '%s\n' "$SRC" | grep -nE 'argocd\.management\.[a-z0-9-]+\.[a-z]{2,}' || true)"

# ---- fake repo root + stubs ------------------------------------------------
FAKE="$WORKDIR/repo"
mkdir -p "$FAKE/tests/live/checks/after" "$FAKE/tests/live/lib" "$FAKE/tests/integration/lib" \
         "$WORKDIR/bin"
ln -s "$REAL_REPO_ROOT/tests/live/lib/live-lib.sh"        "$FAKE/tests/live/lib/live-lib.sh"
ln -s "$REAL_REPO_ROOT/tests/integration/lib/test-lib.sh" "$FAKE/tests/integration/lib/test-lib.sh"
ln -s "$REAL_REPO_ROOT/tests/lib"                         "$FAKE/tests/lib"
ln -s "$REAL_REPO_ROOT/scripts"                           "$FAKE/scripts"
cp "$CHECK_SRC" "$FAKE/tests/live/checks/after/"
CHECK="$FAKE/tests/live/checks/after/$(basename "$CHECK_SRC")"

printf '%s' "$PW" > "$WORKDIR/pw"

# Stub aws. Scenario knobs (files in $WORKDIR): zone=none, hub=none,
# secret=none. Every call's argv is logged.
cat > "$WORKDIR/bin/aws" <<'SHIM'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >> "$W/argv.log"
case "$*" in
  *get-caller-identity*) echo '{"Account":"123456789012"}' ;;
  *"route53 list-hosted-zones"*)
    if [ -f "$W/zone-none" ]; then
      echo '{"HostedZones":[{"Name":"internal.example.","Config":{"PrivateZone":true}}]}'
    else
      echo '{"HostedZones":[{"Name":"internal.example.","Config":{"PrivateZone":true}},{"Name":"example-platform.test.","Config":{"PrivateZone":false}}]}'
    fi ;;
  *"eks describe-cluster"*)
    if [ -f "$W/hub-none" ]; then
      echo "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found" >&2; exit 254
    fi
    echo ACTIVE ;;
  *"secretsmanager describe-secret"*|*"secretsmanager get-secret-value"*)
    if [ -f "$W/secret-none" ]; then
      echo "An error occurred (ResourceNotFoundException) when calling the operation: Secrets Manager can't find the specified secret." >&2; exit 254
    fi
    case "$*" in
      *describe-secret*)  echo "k8-platform/management/argocd-admin" ;;
      *VersionId*)        echo "v-0001" ;;
      *SecretString*)     cat "$W/pw"; echo ;;
    esac ;;
  *) exit 0 ;;
esac
SHIM
# Stub curl: Argo CD's /api/v1/session — 200 iff the JSON body on stdin carries
# admin + the accepted password ($W/accepted), else 401.
cat > "$WORKDIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$W/argv.log"
body="$(cat)"
case "$*" in *"https://argocd.management.example-platform.test/api/v1/session"*) : ;; *) printf '000'; exit 6 ;; esac
u="$(printf '%s' "$body" | jq -r .username)"; p="$(printf '%s' "$body" | jq -r .password)"
if [ "$u" = "admin" ] && [ "$p" = "$(cat "$W/accepted")" ]; then printf '200'; else printf '401'; fi
SHIM
chmod +x "$WORKDIR/bin/aws" "$WORKDIR/bin/curl"

# run_check <scenario-files...> — "<rc>|<output>"; resets the scenario first.
run_check() {
  rm -f "$WORKDIR"/zone-none "$WORKDIR"/hub-none "$WORKDIR"/secret-none "$WORKDIR/argv.log"
  cp "$WORKDIR/pw" "$WORKDIR/accepted"
  local f out rc
  for f in "$@"; do
    case "$f" in refused) printf 'something-else' > "$WORKDIR/accepted" ;; *) : > "$WORKDIR/$f" ;; esac
  done
  : > "$WORKDIR/argv.log"
  out="$(env W="$WORKDIR" PATH="$WORKDIR/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin" \
          AWS_REGION=us-east-1 ARGOCD_LOGIN_TRIES=1 ARGOCD_LOGIN_SLEEP=0 \
          bash "$CHECK" 2>&1)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}
rc_of()  { printf '%s' "${1%%|*}"; }
out_of() { printf '%s' "${1#*|}"; }

# no_leak <label> <result> — the password is in neither the output nor any argv.
no_leak() {
  assert_eq "$1: password not in output" "" "$(out_of "$2" | grep -F -- "$PW" || true)"
  assert_eq "$1: password not in any argv" "" "$(grep -F -- "$PW" "$WORKDIR/argv.log" || true)"
}

echo ""
echo "── (b) ASM value logs in => PASS ────────────────────────────────────"
R="$(run_check)"
assert_eq "accepted ⇒ pass (0)" 0 "$(rc_of "$R")"
assert_contains "names the secret" "$SECRET" "$(out_of "$R")"
assert_contains "states the result" "logs in" "$(out_of "$R")"
assert_eq "no COVERS line on pass" "" "$(out_of "$R" | grep '^COVERS' || true)"
assert_contains "the login went to the discovered hub URL" \
  "https://argocd.management.example-platform.test/api/v1/session" "$(cat "$WORKDIR/argv.log")"
no_leak "pass" "$R"

echo ""
echo "── (c) ASM value refused => FAIL ────────────────────────────────────"
R="$(run_check refused)"
assert_eq "refused ⇒ fail (1), not skip" 1 "$(rc_of "$R")"
assert_contains "names the secret" "$SECRET" "$(out_of "$R")"
assert_contains "says it does NOT log in" "does NOT log in" "$(out_of "$R")"
no_leak "refused" "$R"

echo ""
echo "── (d) secret missing while the hub exists => FAIL ──────────────────"
R="$(run_check secret-none)"
assert_eq "secret missing ⇒ fail (1), not skip" 1 "$(rc_of "$R")"
assert_contains "names the missing secret" "$SECRET" "$(out_of "$R")"
no_leak "secret missing" "$R"

echo ""
echo "── (e) no public hosted zone => SKIP ────────────────────────────────"
R="$(run_check zone-none)"
assert_eq "no zone ⇒ skip (2)" 2 "$(rc_of "$R")"
assert_contains "says why" "no public hosted zone" "$(out_of "$R")"
no_leak "no zone" "$R"

echo ""
echo "── (f) no hub cluster => SKIP ───────────────────────────────────────"
R="$(run_check hub-none)"
assert_eq "no hub ⇒ skip (2)" 2 "$(rc_of "$R")"
assert_contains "says why" "hub cluster" "$(out_of "$R")"
no_leak "no hub" "$R"

assert_summary
