#!/usr/bin/env bash
# k8p-argocd-password.sh — the Argo CD admin password, with AWS Secrets
# Manager as the AUTHORITATIVE copy (kp-2al.44).
#
#   k8p-argocd-password.sh set              new password from a prompt (tty) or one line of stdin
#   k8p-argocd-password.sh set --generate   generate one; it is printed ONCE, labelled
#   k8p-argocd-password.sh show [--reveal]  describe the secret; print the password only with --reveal
#   k8p-argocd-password.sh check            does the ASM value log in to Argo CD right now?
#
# Where things live:
#   ASM secret   k8-platform/management/argocd-admin (override: ARGOCD_SECRET_ID)
#                Terraform seeds it once (terraform/management/argocd-credentials.tf,
#                ignore_changes) and never overwrites it after that.
#   Argo CD      https://argocd.management.<domain> (override: ARGOCD_SERVER); the
#                domain is discovered the same way the build discovers it.
#   Hub cluster  $HUB_CLUSTER (default k8-platform-mgmt), via scripts/opsbox/lib.sh.
#
# How `set` works, and why:
#   1. Write the new value as a new ASM version. put-secret-value makes it
#      AWSCURRENT and the old one AWSPREVIOUS — the old value is the rollback.
#   2. Apply it to Argo CD by patching a bcrypt hash into argocd-secret and
#      restarting argocd-server — the SAME mechanism Terraform uses, so there is
#      one way the password gets into Argo CD. (`argocd account update-password`
#      was rejected: it needs the old password to be what Argo CD currently
#      accepts, so it cannot repair drift, and it takes both passwords on argv.)
#   3. Verify by logging in: POST /api/v1/session, the endpoint `argocd login`
#      calls, with the JSON body on stdin — so the password is never on a
#      command line and the operator's ~/.config/argocd context is not touched.
#   4. If 2 or 3 fails: move AWSCURRENT back to the old version, re-apply the
#      old password to Argo CD, verify it, and say so loudly. Exit non-zero.
#
# The password is never put on a process command line: ASM gets it via a
# mode-600 file:// argument, htpasswd and curl via stdin.
#
# Needs: aws, kubectl, htpasswd (apache2-utils / httpd-tools), jq, curl. IAM:
# secretsmanager Get/Put/UpdateSecretVersionStage/Describe on the secret, and
# admin on the hub cluster (the ops box role has both).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/opsbox/lib.sh
. "$HERE/opsbox/lib.sh"

SECRET_ID="${ARGOCD_SECRET_ID:-k8-platform/management/argocd-admin}"
LOGIN_TRIES="${LOGIN_TRIES:-20}"
LOGIN_SLEEP="${LOGIN_SLEEP:-6}"
MIN_LEN=8
MAX_LEN=72   # bcrypt ignores bytes past 72

WORK="$(mktemp -d -t k8p-argocd-pw-XXXXXX)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

die() { red "$1"; shift; for l in "$@"; do info "$l"; done; exit 1; }

# ---- ASM ------------------------------------------------------------------
asm_current_id() {
  aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
    --version-stage AWSCURRENT --query VersionId --output text 2>/dev/null
}
asm_current_value() {
  aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
    --version-stage AWSCURRENT --query SecretString --output text 2>/dev/null
}
# asm_put <value> — prints the new VersionId.
asm_put() {
  local f="$WORK/value"
  ( umask 077; printf '%s' "$1" > "$f" )
  aws secretsmanager put-secret-value --secret-id "$SECRET_ID" \
    --secret-string "file://$f" --query VersionId --output text
  local rc=$?
  rm -f "$f"
  return "$rc"
}
# asm_restore <old-id> <new-id> — move AWSCURRENT back to <old-id>.
asm_restore() {
  aws secretsmanager update-secret-version-stage --secret-id "$SECRET_ID" \
    --version-stage AWSCURRENT --move-to-version-id "$1" --remove-from-version-id "$2" >/dev/null
}

# ---- Argo CD --------------------------------------------------------------
argocd_server() {
  if [ -n "${ARGOCD_SERVER:-}" ]; then printf '%s' "${ARGOCD_SERVER%/}"; return 0; fi
  local dom; dom="$(platform_domain)"
  [ -n "$dom" ] && [ "$dom" != "None" ] || return 1
  printf 'https://argocd.management.%s' "$dom"
}

# argo_apply <password> — hash, patch argocd-secret, restart argocd-server.
# $2y -> $2a: Go's bcrypt (Argo CD) rejects htpasswd's $2y prefix.
# SC2016: the '$2y'/'$2a' literals are bcrypt prefixes, not shell expansions.
# shellcheck disable=SC2016
argo_apply() {
  local hash mtime f="$WORK/patch.json"
  hash="$(printf '%s\n' "$1" | htpasswd -niBC 10 "" | tr -d ':\n' | sed 's/$2y/$2a/')"
  case "$hash" in '$2a$'*) : ;; *) info "htpasswd did not produce a bcrypt hash"; return 1 ;; esac
  mtime="$(date -u +%FT%TZ)"
  ( umask 077
    printf '{"stringData":{"admin.password":"%s","admin.passwordMtime":"%s"}}\n' "$hash" "$mtime" > "$f" )
  kc "$HUB_CLUSTER" -n argocd patch secret argocd-secret --type merge --patch-file "$f" >/dev/null \
    || { info "kubectl patch of argocd-secret failed"; return 1; }
  kc "$HUB_CLUSTER" -n argocd rollout restart deploy/argocd-server >/dev/null \
    || { info "kubectl rollout restart deploy/argocd-server failed"; return 1; }
  kc "$HUB_CLUSTER" -n argocd rollout status deploy/argocd-server --timeout=300s >/dev/null \
    || { info "argocd-server did not finish rolling out"; return 1; }
}

# argo_login_once <password> — 0 iff Argo CD issues a session for admin.
argo_login_once() {
  local code
  code="$(printf '%s' "$1" | jq -Rs '{username:"admin",password:.}' \
    | curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
        -H 'Content-Type: application/json' --data-binary @- \
        "$SERVER/api/v1/session" 2>/dev/null)"
  [ "$code" = "200" ]
}
# argo_login <password> — retried: the new pod and the NLB take a moment.
argo_login() {
  local i
  for i in $(seq 1 "$LOGIN_TRIES"); do
    argo_login_once "$1" && return 0
    [ "$i" -lt "$LOGIN_TRIES" ] && sleep "$LOGIN_SLEEP"
  done
  return 1
}

need_tools() {
  local t missing=""
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [ -z "$missing" ] || die "Missing tools:$missing" \
    "htpasswd: 'sudo dnf install -y httpd-tools' (ops box) or 'sudo apt-get install -y apache2-utils'"
}

resolve_server() {
  SERVER="$(argocd_server)" || die "Could not work out the Argo CD URL (no public hosted zone found)." \
    "Set ARGOCD_SERVER=https://argocd.management.<domain> and re-run."
}

# ---- commands -------------------------------------------------------------
cmd_show() {
  local reveal=0
  case "${1:-}" in --reveal) reveal=1 ;; "") : ;; *) usage; exit 2 ;; esac
  need_tools aws
  local meta id
  meta="$(aws secretsmanager describe-secret --secret-id "$SECRET_ID" \
          --query '[ARN,LastChangedDate]' --output text 2>/dev/null)" \
    || die "Cannot read ASM secret $SECRET_ID (does it exist? can these credentials read it?)"
  id="$(asm_current_id)"
  head_ "Argo CD admin password — ASM is authoritative"
  info "secret:        $SECRET_ID"
  info "arn:           $(printf '%s' "$meta" | cut -f1)"
  info "last changed:  $(printf '%s' "$meta" | cut -f2)"
  info "AWSCURRENT:    ${id:-unknown}"
  info "username:      admin"
  if [ "$reveal" -eq 1 ]; then
    local pw; pw="$(asm_current_value)" || die "Cannot read the AWSCURRENT value."
    printf 'Argo CD admin password (user admin): %s\n' "$pw"
  else
    info "The password is not printed. Pass --reveal to print it."
  fi
}

cmd_check() {
  [ $# -eq 0 ] || { usage; exit 2; }
  need_tools aws jq curl
  resolve_server
  local pw; pw="$(asm_current_value)"
  [ -n "$pw" ] || die "Cannot read the AWSCURRENT value of $SECRET_ID."
  if argo_login "$pw"; then
    green "The ASM password ($SECRET_ID, AWSCURRENT $(asm_current_id)) logs in to $SERVER as admin."
  else
    die "The ASM password does NOT log in to $SERVER as admin." \
      "ASM and Argo CD disagree (or Argo CD is unreachable). To re-apply the ASM value:" \
      "terraform -chdir=terraform/management apply -replace=terraform_data.argocd_admin_password"
  fi
}

read_new_password() {
  local a b
  if [ -t 0 ]; then
    IFS= read -rs -p "New Argo CD admin password: " a; echo >&2
    IFS= read -rs -p "Again: " b; echo >&2
    [ "$a" = "$b" ] || die "The two entries differ. Nothing changed."
  else
    IFS= read -r a || [ -n "$a" ] || die "No password on stdin. Nothing changed."
  fi
  NEW="$a"
}

generate_password() {
  NEW="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24 || true)"
  [ "${#NEW}" -eq 24 ] || die "Could not generate a password. Nothing changed."
}

cmd_set() {
  local generate=0
  case "${1:-}" in --generate) generate=1 ;; "") : ;; *) usage; exit 2 ;; esac
  need_tools aws kubectl htpasswd jq curl

  head_ "Change the Argo CD admin password (ASM: $SECRET_ID)"
  resolve_server
  local old_id old new_id len
  old_id="$(asm_current_id)"
  [ -n "$old_id" ] && [ "$old_id" != "None" ] || die "Cannot read ASM secret $SECRET_ID. Nothing changed."
  old="$(asm_current_value)"
  [ -n "$old" ] || die "ASM secret $SECRET_ID has no AWSCURRENT value. Nothing changed."
  kc "$HUB_CLUSTER" -n argocd get secret argocd-secret -o name >/dev/null 2>&1 \
    || die "Cannot reach argocd-secret on $HUB_CLUSTER. Nothing changed."
  info "current ASM version: $old_id"
  info "Argo CD:             $SERVER"

  NEW=""
  if [ "$generate" -eq 1 ]; then generate_password; else read_new_password; fi
  len="$(printf '%s' "$NEW" | LC_ALL=C wc -c | tr -d ' ')"
  [ "$len" -ge "$MIN_LEN" ] || die "Too short (minimum $MIN_LEN characters). Nothing changed."
  [ "$len" -le "$MAX_LEN" ] || die "Too long (maximum $MAX_LEN bytes; bcrypt ignores the rest). Nothing changed."
  [ "$NEW" != "$old" ] || die "That is already the current password. Nothing changed."

  new_id="$(asm_put "$NEW")"
  if [ -z "$new_id" ] || [ "$new_id" = "None" ]; then
    die "Writing the new version to ASM failed. Nothing changed (ASM and Argo CD untouched)."
  fi
  green "ASM: new AWSCURRENT version $new_id (previous $old_id is now AWSPREVIOUS)."

  if argo_apply "$NEW" && argo_login "$NEW"; then
    green "Argo CD: the new password is applied and logs in to $SERVER as admin."
    if [ "$generate" -eq 1 ]; then
      printf '\nNew Argo CD admin password (user admin), shown once: %s\n' "$NEW"
      info "It is stored in ASM; read it again later with: $0 show --reveal"
    fi
    return 0
  fi

  # ---- rollback ----------------------------------------------------------
  printf '\n%s!!! APPLYING THE NEW PASSWORD TO ARGO CD FAILED — ROLLING BACK !!!%s\n' "$C_BOLD$C_RED" "$C_OFF"
  local rc=1 asm_ok=1
  if asm_restore "$old_id" "$new_id"; then
    red "ROLLED BACK: ASM AWSCURRENT is again version $old_id (the previous password)."
  else
    asm_ok=0
    red "ROLLBACK FAILED: ASM AWSCURRENT is still the NEW version $new_id. Move it back by hand:"
    info "aws secretsmanager update-secret-version-stage --secret-id $SECRET_ID \\"
    info "  --version-stage AWSCURRENT --move-to-version-id $old_id --remove-from-version-id $new_id"
  fi
  if argo_apply "$old" && argo_login "$old"; then
    red "ROLLED BACK: Argo CD is back on the previous password, and it logs in."
  else
    red "Argo CD could NOT be put back on the previous password."
    info "Once ASM's AWSCURRENT is right, re-apply it with:"
    info "terraform -chdir=terraform/management apply -replace=terraform_data.argocd_admin_password"
  fi
  [ "$asm_ok" -eq 1 ] && info "Then: $0 check"
  red "The password was NOT changed."
  return "$rc"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    set)   cmd_set "$@" ;;
    show)  cmd_show "$@" ;;
    check) cmd_check "$@" ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
