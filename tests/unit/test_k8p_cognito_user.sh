#!/usr/bin/env bash
# kp-2al.43 — scripts/k8p-cognito-user.sh (add / remove / list directory users).
#
# Drives the script against a STATEFUL stubbed `aws` on PATH: the stub keeps a
# tiny user directory on disk, records every call's argv, and captures the
# set-password request body. No AWS, no network.
#
# The load-bearing assertion besides behaviour: the password never appears in
# stdout/stderr (except the single labelled --generate line) and never in any
# recorded argv — it travels only in a 0600 --cli-input-json file.
# shellcheck disable=SC2015  # `cond && _pass || _fail`: _pass always returns 0
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

SCRIPT="scripts/k8p-cognito-user.sh"
T="$(mktemp -d -t k8p-cognito-test-XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/aws" <<'STUB'
#!/usr/bin/env bash
# Stateful aws stub. State: $STUB_DIR/users/<email>/{status,groups}.
set -u
D="$STUB_DIR"
printf '%s\n' "$*" >> "$D/calls.log"
svc="${1:-}"; op="${2:-}"; shift 2 2>/dev/null || true
arg() { local k="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { printf '%s' "$2"; return; }; shift; done; }
user="$(arg --username "$@")"; user="${user#uuid-}"
if [ -n "${STUB_FAIL:-}" ] && [ "$op" = "$STUB_FAIL" ]; then
  echo "" >&2
  echo "An error occurred (InvalidPasswordException) when calling the ${op} operation: Password does not conform to policy" >&2
  exit 254
fi
notfound() { echo "An error occurred (UserNotFoundException) when calling the AdminGetUser operation: User does not exist." >&2; exit 254; }
case "$svc $op" in
  "configure get") exit 1 ;;
  "secretsmanager get-secret-value")
    jq -n '{SecretString: ({issuer_url: "https://cognito-idp.eu-west-2.amazonaws.com/eu-west-2_TESTPOOL", client_secret: "CLIENT-SECRET-MUST-NOT-PRINT"} | tojson)}' ;;
  "cognito-idp get-group")
    g="$(arg --group-name "$@")"
    case "$g" in k8s-admins|k8s-viewers) echo '{}' ;; *) echo "ResourceNotFoundException" >&2; exit 254 ;; esac ;;
  "cognito-idp admin-get-user")
    [ -d "$D/users/$user" ] || notfound
    jq -n --arg u "$user" --arg s "$(cat "$D/users/$user/status")" \
      '{Username: ("uuid-" + $u), UserStatus: $s, Enabled: true}' ;;
  "cognito-idp admin-create-user")
    [ -d "$D/users/$user" ] && { echo "An error occurred (UsernameExistsException)" >&2; exit 254; }
    mkdir -p "$D/users/$user"; echo FORCE_CHANGE_PASSWORD > "$D/users/$user/status"; : > "$D/users/$user/groups"
    echo '{}' ;;
  "cognito-idp admin-set-user-password")
    f="$(arg --cli-input-json "$@")"; f="${f#file://}"
    cp "$f" "$D/set-password.$(date +%s%N).json"
    stat -c '%a' "$f" > "$D/set-password.mode"
    user="$(jq -r .Username "$f")"
    [ -d "$D/users/$user" ] || notfound
    [ "$(jq -r .Permanent "$f")" = true ] && echo CONFIRMED > "$D/users/$user/status"
    echo '{}' ;;
  "cognito-idp admin-add-user-to-group")
    [ -d "$D/users/$user" ] || notfound
    g="$(arg --group-name "$@")"
    grep -qx "$g" "$D/users/$user/groups" || echo "$g" >> "$D/users/$user/groups"
    echo '{}' ;;
  "cognito-idp admin-list-groups-for-user")
    [ -d "$D/users/$user" ] || notfound
    jq -R . < "$D/users/$user/groups" | jq -s '{Groups: map({GroupName: .})}' ;;
  "cognito-idp admin-delete-user")
    [ -d "$D/users/$user" ] || notfound
    rm -rf "$D/users/$user"; echo '{}' ;;
  "cognito-idp list-users")
    for u in "$D"/users/*; do
      [ -d "$u" ] || continue
      jq -n --arg e "$(basename "$u")" --arg s "$(cat "$u/status")" \
        '{Username: ("uuid-" + $e), UserStatus: $s, Enabled: true, Attributes: [{Name: "email", Value: $e}]}'
    done | jq -s '{Users: .}' ;;
  *) echo "stub: unhandled: $svc $op" >&2; exit 99 ;;
esac
STUB
chmod +x "$T/bin/aws"

reset_world() {
  rm -rf "$T/world"; mkdir -p "$T/world/users"; : > "$T/world/calls.log"
}
# run_script <stdin-text> <args...>; sets RC, OUT (stdout+stderr).
run_script() {
  local input="$1"; shift
  OUT="$(printf '%s' "$input" | env PATH="$T/bin:$PATH" STUB_DIR="$T/world" \
           AWS_REGION=us-east-1 bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}
seed_user() {  # seed_user <email> <status> <group...>
  local e="$1" s="$2"; shift 2
  mkdir -p "$T/world/users/$e"; echo "$s" > "$T/world/users/$e/status"
  : > "$T/world/users/$e/groups"; for g in "$@"; do echo "$g" >> "$T/world/users/$e/groups"; done
}
not_contains() {  # not_contains <name> <needle> <haystack>
  if printf '%s' "$3" | grep -qF -- "$2"; then _fail "$1" "found forbidden text"; else _pass "$1"; fi
}

PW="Sekrit-Unit-Pw-4242Ab"
EMAIL="alice@example.com"

[ -f "$SCRIPT" ] || { _fail "script exists: $SCRIPT"; assert_summary; exit 1; }

echo "── add: new user (password from stdin) ──"
reset_world
run_script "$PW"$'\n' add "$EMAIL" --password-stdin
assert_eq "add new: exit 0" 0 "$RC"
assert_contains "discovery names the secret" "secret:  k8-platform/base/cognito" "$OUT"
assert_contains "discovery names the pool id" "pool:    eu-west-2_TESTPOOL" "$OUT"
assert_contains "discovery names the pool region" "region:  eu-west-2" "$OUT"
assert_contains "add new: created" "user:     created" "$OUT"
assert_contains "add new: verification status CONFIRMED" "status:  CONFIRMED" "$OUT"
assert_contains "add new: default group k8s-admins verified" "groups:  k8s-admins" "$OUT"
assert_contains "add new: calls run in the pool's region" "--region eu-west-2" "$(grep admin-create-user "$T/world/calls.log")"
not_contains "add new: password not in output" "$PW" "$OUT"
not_contains "add new: password not in any argv" "$PW" "$(cat "$T/world/calls.log")"
not_contains "add new: client secret never printed" "CLIENT-SECRET-MUST-NOT-PRINT" "$OUT"
assert_eq "add new: password delivered via request body" "$PW" "$(jq -r .Password "$T"/world/set-password.*.json 2>/dev/null | head -1)"
assert_eq "add new: request file is 0600" 600 "$(cat "$T/world/set-password.mode" 2>/dev/null)"
assert_eq "add new: request marks password permanent" true "$(jq -r .Permanent "$T"/world/set-password.*.json 2>/dev/null | head -1)"
grep -q 'admin-get-user' "$T/world/calls.log" && grep -q 'admin-list-groups-for-user' "$T/world/calls.log" \
  && _pass "add new: verification read issued" || _fail "add new: verification read issued"
grep -q -- 'Name=given_name,Value=alice' "$T/world/calls.log" \
  && _pass "add new: given_name defaults to the email local part" || _fail "add new: given_name defaults to the email local part"

echo "── add: --group k8s-viewers ──"
reset_world
run_script "$PW" add bob@example.com --group k8s-viewers --password-stdin
assert_eq "add viewer: exit 0" 0 "$RC"
assert_contains "add viewer: in k8s-viewers" "groups:  k8s-viewers" "$OUT"

echo "── add: existing user, no --reset-password ──"
reset_world
seed_user "$EMAIL" CONFIRMED k8s-viewers
run_script "$PW" add "$EMAIL" --password-stdin
assert_eq "add existing: exit 0" 0 "$RC"
assert_contains "add existing: not re-created" "already exists" "$OUT"
assert_contains "add existing: password unchanged" "password: unchanged" "$OUT"
assert_contains "add existing: group ensured (both groups)" "groups:  k8s-admins k8s-viewers" "$OUT"
grep -q 'admin-create-user' "$T/world/calls.log" && _fail "add existing: no admin-create-user" || _pass "add existing: no admin-create-user"
grep -q 'admin-set-user-password' "$T/world/calls.log" && _fail "add existing: no admin-set-user-password" || _pass "add existing: no admin-set-user-password"
not_contains "add existing: password not in output" "$PW" "$OUT"

echo "── add: existing user, --reset-password ──"
reset_world
seed_user "$EMAIL" FORCE_CHANGE_PASSWORD k8s-admins
run_script "$PW" add "$EMAIL" --password-stdin --reset-password
assert_eq "add reset: exit 0" 0 "$RC"
assert_contains "add reset: password set" "password: set (permanent)" "$OUT"
assert_contains "add reset: status CONFIRMED" "status:  CONFIRMED" "$OUT"
not_contains "add reset: password not in argv" "$PW" "$(cat "$T/world/calls.log")"

echo "── add: --generate prints the password once, labelled ──"
reset_world
run_script "" add carol@example.com --generate
assert_eq "generate: exit 0" 0 "$RC"
GEN="$(printf '%s\n' "$OUT" | sed -n 's/^GENERATED PASSWORD (shown once[^:]*: //p')"
[ -n "$GEN" ] && _pass "generate: labelled password line present" || _fail "generate: labelled password line present" "$OUT"
assert_eq "generate: password appears exactly once in output" 1 "$(printf '%s\n' "$OUT" | grep -cF -- "${GEN:-<none>}")"
assert_eq "generate: printed password is the one set" "$GEN" "$(jq -r .Password "$T"/world/set-password.*.json 2>/dev/null | head -1)"
not_contains "generate: password not in argv" "${GEN:-<none>}" "$(cat "$T/world/calls.log")"
printf '%s' "$GEN" | grep -qE '^[A-Za-z0-9]{20}$' && printf '%s' "$GEN" | grep -q '[a-z]' \
  && printf '%s' "$GEN" | grep -q '[A-Z]' && printf '%s' "$GEN" | grep -q '[0-9]' \
  && _pass "generate: password meets the pool policy" || _fail "generate: password meets the pool policy" "$GEN"

echo "── add: --generate on an existing user without reset prints no password ──"
reset_world
seed_user carol@example.com CONFIRMED k8s-admins
run_script "" add carol@example.com --generate
assert_eq "generate existing: exit 0" 0 "$RC"
not_contains "generate existing: no password line" "GENERATED PASSWORD" "$OUT"

echo "── add: refuses --password on the command line ──"
reset_world
run_script "" add "$EMAIL" --password "$PW"
[ "$RC" -ne 0 ] && _pass "--password rejected (non-zero)" || _fail "--password rejected (non-zero)"
not_contains "--password: value not echoed" "$PW" "$OUT"

echo "── add: no terminal and no password source fails cleanly ──"
reset_world
if command -v setsid >/dev/null 2>&1; then
  OUT="$(env PATH="$T/bin:$PATH" STUB_DIR="$T/world" AWS_REGION=us-east-1 \
           setsid bash "$SCRIPT" add "$EMAIL" </dev/null 2>&1)"; RC=$?
  [ "$RC" -ne 0 ] && _pass "no tty: non-zero" || _fail "no tty: non-zero"
  assert_contains "no tty: says how to supply a password" "use --password-stdin or --generate" "$OUT"
  grep -q 'admin-create-user' "$T/world/calls.log" && _fail "no tty: nothing created" || _pass "no tty: nothing created"
else
  echo "  (setsid not installed — skipping)"
fi

echo "── add: rejects an unknown group ──"
reset_world
run_script "$PW" add "$EMAIL" --group cluster-gods --password-stdin
[ "$RC" -ne 0 ] && _pass "bad group: non-zero" || _fail "bad group: non-zero"

echo "── failure path: AWS error surfaces its last line ──"
reset_world
OUT="$(printf '%s' "$PW" | env PATH="$T/bin:$PATH" STUB_DIR="$T/world" STUB_FAIL=admin-set-user-password \
         AWS_REGION=us-east-1 bash "$SCRIPT" add "$EMAIL" --password-stdin 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && _pass "failure: non-zero exit" || _fail "failure: non-zero exit"
assert_contains "failure: names the step" "admin-set-user-password for $EMAIL failed" "$OUT"
assert_contains "failure: AWS error last line" "Password does not conform to policy" "$OUT"
not_contains "failure: password not in output" "$PW" "$OUT"
not_contains "failure: no verification OK" "  OK" "$OUT"

echo "── remove ──"
reset_world
seed_user "$EMAIL" CONFIRMED k8s-admins
run_script "" remove "$EMAIL"
assert_eq "remove: exit 0" 0 "$RC"
assert_contains "remove: deleted" "user:    deleted" "$OUT"
assert_contains "remove: verified absent" "verified absent: $EMAIL" "$OUT"
[ -d "$T/world/users/$EMAIL" ] && _fail "remove: user gone from the world" || _pass "remove: user gone from the world"
run_script "" remove "$EMAIL"
assert_eq "remove absent: exit 0" 0 "$RC"
assert_contains "remove absent: nothing to do" "nothing to do" "$OUT"

echo "── list ──"
reset_world
run_script "" list
assert_eq "list empty: exit 0" 0 "$RC"
assert_contains "list empty: explicit no-users line" "no users in pool eu-west-2_TESTPOOL" "$OUT"
seed_user "$EMAIL" CONFIRMED k8s-admins k8s-viewers
seed_user bob@example.com FORCE_CHANGE_PASSWORD k8s-viewers
run_script "" list
assert_eq "list: exit 0" 0 "$RC"
assert_contains "list: alice row with groups" "k8s-admins k8s-viewers" "$(printf '%s\n' "$OUT" | grep alice@example.com)"
assert_contains "list: bob row with status" "FORCE_CHANGE_PASSWORD" "$(printf '%s\n' "$OUT" | grep bob@example.com)"
assert_contains "list: count" "2 user(s)" "$OUT"

echo "── static ──"
bash -n "$SCRIPT" && _pass "syntax" || _fail "syntax"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$SCRIPT" >/dev/null 2>&1 && _pass "shellcheck clean" \
    || _fail "shellcheck clean" "$(shellcheck -x "$SCRIPT" 2>&1 | head -5)"
fi
[ -L scripts/opsbox/k8p-cognito-user.sh ] && [ "$(readlink -f scripts/opsbox/k8p-cognito-user.sh)" = "$(readlink -f "$SCRIPT")" ] \
  && _pass "on the ops-box PATH (scripts/opsbox symlink)" || _fail "on the ops-box PATH (scripts/opsbox symlink)"
for a in AdminDeleteUser ListUsers AdminGetUser AdminListGroupsForUser AdminSetUserPassword AdminCreateUser AdminAddUserToGroup GetGroup; do
  grep -q "cognito-idp:$a\"" terraform/opsbox/main.tf && _pass "ops-box role grants cognito-idp:$a" \
    || _fail "ops-box role grants cognito-idp:$a"
done

assert_summary
