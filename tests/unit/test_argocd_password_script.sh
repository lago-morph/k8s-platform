#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # pass/fail one-liners; $2a$10$ is a bcrypt prefix
# kp-2al.44 — scripts/k8p-argocd-password.sh against a MOCKED world.
#
# The script moves a credential between two systems (ASM and Argo CD). The
# failure that matters is the two disagreeing: ASM says X, Argo CD accepts Y,
# and the documented password no longer logs in. So these tests model both
# sides with state, not canned answers:
#   - `aws`      keeps ASM versions + the AWSCURRENT/AWSPREVIOUS labels on disk
#   - `htpasswd` "hashes" stdin as sha256 (deterministic, checkable)
#   - `kubectl`  stores whatever hash is patched into argocd-secret
#   - `curl`     accepts a /api/v1/session login iff sha256(password) matches
#                the stored hash — i.e. Argo CD's real behaviour
# Every shim also logs its argv, so the test can prove the password never
# rides on a command line. No AWS, no cluster, no network.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1   # repo root
# shellcheck disable=SC1091
. tests/unit/lib/test-helpers.sh

SCRIPT="scripts/k8p-argocd-password.sh"
echo "test_argocd_password_script: $SCRIPT"
if [ ! -x "$SCRIPT" ]; then
  fail "script exists and is executable" "$SCRIPT missing or not executable"
  summary
fi

MOCK="$(mktemp -d -t argopw-mock-XXXXXX)"
trap 'rm -rf "$MOCK"' EXIT
mkdir -p "$MOCK/bin" "$MOCK/asm"

OLD_PW="SeedPassw0rdSeedPassw0rd"
NEW_PW="Brand-new pass 9!"

# ---------------------------------------------------------------------------
cat > "$MOCK/bin/aws" <<'SHIM'
#!/usr/bin/env bash
set -u
printf 'aws %s\n' "$*" >> "$MOCK/argv.log"
S="$MOCK/asm"
arg() { # arg <flag> — value following a flag
  local want="$1"; shift
  while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "${2:-}"; return; }; shift; done
}
case "${1:-} ${2:-}" in
  "route53 list-hosted-zones") echo "example.com." ;;
  "eks update-kubeconfig") exit 0 ;;
  "secretsmanager get-secret-value")
    [ -f "$S/AWSCURRENT" ] || { echo "ResourceNotFoundException" >&2; exit 254; }
    id="$(cat "$S/AWSCURRENT")"
    case "$(arg --query "$@")" in
      VersionId)    echo "$id" ;;
      SecretString) cat "$S/v-$id"; echo ;;
      *) exit 2 ;;
    esac ;;
  "secretsmanager describe-secret")
    [ -f "$S/AWSCURRENT" ] || exit 254
    printf '%s\t%s\n' "arn:aws:secretsmanager:us-east-1:123456789012:secret:k8-platform/management/argocd-admin-AbCdEf" "2026-11-27T10:00:00Z" ;;
  "secretsmanager put-secret-value")
    [ "${MOCK_PUT_RC:-0}" -eq 0 ] || exit "$MOCK_PUT_RC"
    src="$(arg --secret-string "$@")"
    case "$src" in file://*) : ;; *) echo "secret-string must be file://" >&2; exit 9 ;; esac
    n=$(( $(cat "$S/counter" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/counter"
    id="ver-$n"
    cat "${src#file://}" > "$S/v-$id"
    cp "$S/AWSCURRENT" "$S/AWSPREVIOUS"; echo "$id" > "$S/AWSCURRENT"
    echo "$id" ;;
  "secretsmanager update-secret-version-stage")
    [ "${MOCK_RESTORE_RC:-0}" -eq 0 ] || exit "$MOCK_RESTORE_RC"
    [ "$(arg --version-stage "$@")" = AWSCURRENT ] || exit 2
    [ "$(arg --remove-from-version-id "$@")" = "$(cat "$S/AWSCURRENT")" ] || exit 3
    cp "$S/AWSCURRENT" "$S/AWSPREVIOUS"; arg --move-to-version-id "$@" > "$S/AWSCURRENT" ;;
  *) exit 0 ;;
esac
SHIM

cat > "$MOCK/bin/htpasswd" <<'SHIM'
#!/usr/bin/env bash
printf 'htpasswd %s\n' "$*" >> "$MOCK/argv.log"
case "${1:-}" in -*i*) : ;; *) echo "htpasswd: password must come on stdin (-i)" >&2; exit 9 ;; esac
IFS= read -r pw
printf ':$2y$10$%s\n' "$(printf '%s' "$pw" | sha256sum | cut -c1-53)"
SHIM

cat > "$MOCK/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
set -u
printf 'kubectl %s\n' "$*" >> "$MOCK/argv.log"
all=" $* "
case "$all" in
  *" patch secret argocd-secret "*)
    n=$(( $(cat "$MOCK/patches" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$MOCK/patches"
    [ "${MOCK_PATCH_FAIL_ON:-0}" = "$n" ] && { echo "error: patch refused" >&2; exit 1; }
    f=""; prev=""
    for a in "$@"; do [ "$prev" = "--patch-file" ] && f="$a"; prev="$a"; done
    [ -n "$f" ] || { echo "expected --patch-file" >&2; exit 9; }
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stringData"]["admin.password"])' "$f" \
      > "$MOCK/argo_hash" ;;
  *" rollout status "*)
    n=$(( $(cat "$MOCK/rollouts" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$MOCK/rollouts"
    [ "${MOCK_ROLLOUT_FAIL_ON:-0}" = "$n" ] && { echo "error: timed out waiting for rollout" >&2; exit 1; }
    exit 0 ;;
  *" get secret argocd-secret "*) echo "argocd-secret" ;;
  *) exit 0 ;;
esac
SHIM

cat > "$MOCK/bin/curl" <<'SHIM'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$MOCK/argv.log"
body="$(cat)"
pw="$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"], end="")')"
want="$(cat "$MOCK/argo_hash" 2>/dev/null)"
got='$2a$10$'"$(printf '%s' "$pw" | sha256sum | cut -c1-53)"
if [ "$got" = "$want" ]; then printf '200'; else printf '401'; fi
SHIM
chmod +x "$MOCK"/bin/*

# reset_world — ASM holds OLD_PW as AWSCURRENT (version ver-0); Argo CD accepts it.
reset_world() {
  rm -f "$MOCK"/asm/* "$MOCK"/argv.log "$MOCK"/patches "$MOCK"/rollouts
  printf '%s' "$OLD_PW" > "$MOCK/asm/v-ver-0"
  echo ver-0 > "$MOCK/asm/AWSCURRENT"
  echo 0 > "$MOCK/asm/counter"
  printf '%s' '$2a$10$'"$(printf '%s' "$OLD_PW" | sha256sum | cut -c1-53)" > "$MOCK/argo_hash"
  : > "$MOCK/argv.log"
}
asm_current_value() { cat "$MOCK/asm/v-$(cat "$MOCK/asm/AWSCURRENT")"; }
argo_accepts() {
  [ "$(cat "$MOCK/argo_hash")" = '$2a$10$'"$(printf '%s' "$1" | sha256sum | cut -c1-53)" ]
}

run() { # run <stdin> <args...> — sets OUT, RC
  local input="$1"; shift
  OUT="$(printf '%s' "$input" | env MOCK="$MOCK" PATH="$MOCK/bin:$PATH" \
         NO_COLOR=1 LOGIN_TRIES=2 LOGIN_SLEEP=0 bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  # SHOW_OUT=1 prints each run's output (debug aid; passwords are fake).
  [ -z "${SHOW_OUT:-}" ] || printf -- '--- %s (rc=%s)\n%s\n' "$*" "$RC" "$OUT" >&2
}
no_secret_in() { # no_secret_in <name> <text> <pw...>
  local name="$1" text="$2"; shift 2
  for p in "$@"; do
    case "$text" in *"$p"*) fail "$name" "a password appears in it"; return ;; esac
  done
  pass "$name"
}

# --- happy path: set from stdin --------------------------------------------
reset_world
run "$NEW_PW"$'\n' set
[ "$RC" -eq 0 ] && pass "set (stdin) exits 0" || fail "set (stdin) exits 0" "rc=$RC out=$OUT"
[ "$(asm_current_value)" = "$NEW_PW" ] && pass "set: ASM AWSCURRENT is the new password" \
  || fail "set: ASM AWSCURRENT is the new password"
[ "$(cat "$MOCK/asm/AWSPREVIOUS")" = ver-0 ] && pass "set: the old version is AWSPREVIOUS" \
  || fail "set: the old version is AWSPREVIOUS"
argo_accepts "$NEW_PW" && pass "set: Argo CD now accepts the new password" \
  || fail "set: Argo CD now accepts the new password"
case "$OUT" in *"logs in"*) pass "set: reports the login verification" ;;
  *) fail "set: reports the login verification" "$OUT" ;; esac
no_secret_in "set: output never contains a password" "$OUT" "$NEW_PW" "$OLD_PW"
no_secret_in "set: no password on any command line" "$(cat "$MOCK/argv.log")" "$NEW_PW" "$OLD_PW"
grep -q 'argocd.management.example.com/api/v1/session' "$MOCK/argv.log" \
  && pass "set: verifies against the hub's discovered argocd URL" \
  || fail "set: verifies against the hub's discovered argocd URL"

# --- apply fails (patch refused) -> ASM rolled back -------------------------
reset_world
MOCK_PATCH_FAIL_ON=1 run "$NEW_PW"$'\n' set
[ "$RC" -ne 0 ] && pass "patch-fails: exits non-zero" || fail "patch-fails: exits non-zero" "$OUT"
[ "$(cat "$MOCK/asm/AWSCURRENT")" = ver-0 ] && pass "patch-fails: ASM AWSCURRENT moved back to the old version" \
  || fail "patch-fails: ASM AWSCURRENT moved back to the old version" "AWSCURRENT=$(cat "$MOCK/asm/AWSCURRENT")"
argo_accepts "$OLD_PW" && pass "patch-fails: Argo CD still accepts the old password" \
  || fail "patch-fails: Argo CD still accepts the old password"
case "$OUT" in *"ROLLED BACK"*) pass "patch-fails: says ROLLED BACK loudly" ;;
  *) fail "patch-fails: says ROLLED BACK loudly" "$OUT" ;; esac
no_secret_in "patch-fails: output never contains a password" "$OUT" "$NEW_PW" "$OLD_PW"

# --- apply half-done (patched, rollout fails) -> ASM AND Argo CD restored ---
reset_world
MOCK_ROLLOUT_FAIL_ON=1 run "$NEW_PW"$'\n' set
[ "$RC" -ne 0 ] && pass "rollout-fails: exits non-zero" || fail "rollout-fails: exits non-zero" "$OUT"
[ "$(cat "$MOCK/asm/AWSCURRENT")" = ver-0 ] && pass "rollout-fails: ASM rolled back" \
  || fail "rollout-fails: ASM rolled back"
argo_accepts "$OLD_PW" && pass "rollout-fails: Argo CD re-applied to the old password" \
  || fail "rollout-fails: Argo CD re-applied to the old password"
case "$OUT" in *"ROLLED BACK"*"logs in"*) pass "rollout-fails: reports the restore verified" ;;
  *) fail "rollout-fails: reports the restore verified" "$OUT" ;; esac
no_secret_in "rollout-fails: output never contains a password" "$OUT" "$NEW_PW" "$OLD_PW"

# --- rollback itself fails -> loud, with the exact recovery command ---------
reset_world
MOCK_PATCH_FAIL_ON=1 MOCK_RESTORE_RC=1 run "$NEW_PW"$'\n' set
[ "$RC" -ne 0 ] && pass "rollback-fails: exits non-zero" || fail "rollback-fails: exits non-zero"
case "$OUT" in *"ROLLBACK FAILED"*"update-secret-version-stage"*"ver-0"*) pass "rollback-fails: prints the manual recovery" ;;
  *) fail "rollback-fails: prints the manual recovery" "$OUT" ;; esac
no_secret_in "rollback-fails: output never contains a password" "$OUT" "$NEW_PW" "$OLD_PW"

# --- ASM write fails -> nothing touched in Argo CD --------------------------
reset_world
MOCK_PUT_RC=1 run "$NEW_PW"$'\n' set
[ "$RC" -ne 0 ] && pass "put-fails: exits non-zero" || fail "put-fails: exits non-zero"
[ ! -f "$MOCK/patches" ] && pass "put-fails: Argo CD never patched" || fail "put-fails: Argo CD never patched"

# --- --generate: printed exactly once, labelled, and it is what ASM holds ---
reset_world
run "" set --generate
[ "$RC" -eq 0 ] && pass "set --generate exits 0" || fail "set --generate exits 0" "$OUT"
GEN="$(asm_current_value)"
[ "$GEN" != "$OLD_PW" ] && [ "${#GEN}" -ge 20 ] && pass "set --generate: ASM holds a fresh long password" \
  || fail "set --generate: ASM holds a fresh long password" "len=${#GEN}"
cnt="$(printf '%s\n' "$OUT" | grep -cF -- "$GEN")"
[ "$cnt" -eq 1 ] && pass "set --generate: password printed exactly once" \
  || fail "set --generate: password printed exactly once" "count=$cnt"
printf '%s\n' "$OUT" | grep -F -- "$GEN" | grep -qi 'password' \
  && pass "set --generate: the printed line is labelled" || fail "set --generate: the printed line is labelled"
no_secret_in "set --generate: old password not printed" "$OUT" "$OLD_PW"
no_secret_in "set --generate: no password on any command line" "$(cat "$MOCK/argv.log")" "$GEN" "$OLD_PW"

# --- refuse a no-op / too-short password ------------------------------------
reset_world
run "$OLD_PW"$'\n' set
[ "$RC" -ne 0 ] && [ ! -f "$MOCK/patches" ] && pass "set: refuses the current password, touches nothing" \
  || fail "set: refuses the current password, touches nothing" "$OUT"
no_secret_in "set (same): output never contains a password" "$OUT" "$OLD_PW"
reset_world
run "short"$'\n' set
[ "$RC" -ne 0 ] && [ "$(cat "$MOCK/asm/counter")" = 0 ] && pass "set: refuses a too-short password, ASM untouched" \
  || fail "set: refuses a too-short password, ASM untouched" "$OUT"

# --- show ---------------------------------------------------------------------
reset_world
run "" show
[ "$RC" -eq 0 ] && pass "show exits 0" || fail "show exits 0" "$OUT"
no_secret_in "show without --reveal never prints the password" "$OUT" "$OLD_PW"
case "$OUT" in *"k8-platform/management/argocd-admin"*"--reveal"*) pass "show names the secret and the flag" ;;
  *) fail "show names the secret and the flag" "$OUT" ;; esac
run "" show --reveal
case "$OUT" in *"$OLD_PW"*) pass "show --reveal prints the password" ;;
  *) fail "show --reveal prints the password" ;; esac

# --- check ------------------------------------------------------------------
reset_world
run "" check
[ "$RC" -eq 0 ] && pass "check: ASM value logs in -> exit 0" || fail "check: ASM value logs in -> exit 0" "$OUT"
no_secret_in "check: output never contains a password" "$OUT" "$OLD_PW"
printf '%s' 'drifted' > "$MOCK/argo_hash"
run "" check
[ "$RC" -ne 0 ] && pass "check: drift (Argo CD rejects ASM value) -> non-zero" \
  || fail "check: drift (Argo CD rejects ASM value) -> non-zero" "$OUT"
case "$OUT" in *[A-Za-z]*) pass "check: prints a verdict even when it fails" ;;
  *) fail "check: prints a verdict even when it fails" ;; esac

# --- usage ------------------------------------------------------------------
run "" bogus
[ "$RC" -ne 0 ] && [ -n "$OUT" ] && pass "unknown command: non-zero with usage" \
  || fail "unknown command: non-zero with usage"

# --- static: shellcheck clean -------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  if sc="$(shellcheck -x "$SCRIPT" 2>&1)"; then pass "shellcheck clean"; else fail "shellcheck clean" "$sc"; fi
fi

summary
