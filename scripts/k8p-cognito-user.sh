#!/usr/bin/env bash
# k8p-cognito-user.sh — manage platform directory accounts (Cognito) (kp-2al.43).
#
# The scripted form of docs/site/how-to/admin-access.md section 4, using the
# same chain tests/live/checks/instantiate/cognito-federation-live.sh runs on
# every full-profile Live verify: discover the pool from the committed Cognito
# bridge document, admin-create-user, admin-set-user-password --permanent,
# admin-add-user-to-group.
#
#   k8p-cognito-user.sh add <email> [--group k8s-admins|k8s-viewers]
#                           [--password-stdin | --generate] [--reset-password]
#                           [--given-name NAME] [--family-name NAME]
#   k8p-cognito-user.sh remove <email>
#   k8p-cognito-user.sh list
#
# add      Creates the user (default group k8s-admins) with a PERMANENT
#          password, or, for an existing user, ensures the group membership
#          and changes the password only when --reset-password is given.
#          The password comes from a no-echo prompt, from stdin
#          (--password-stdin, first line), or is generated (--generate) and
#          then printed exactly once, labelled. It is never printed otherwise.
# remove   Deletes the user; a user that does not exist is nothing to do.
# list     Every user in the pool with status and groups; says so when empty.
#
# Every change is followed by a verification read (admin-get-user +
# admin-list-groups-for-user) printed as a short summary. Any AWS failure
# exits non-zero with the last line of the AWS error.
#
# PASSWORD HANDLING: admin-set-user-password only takes the password as a
# parameter. Rather than put it on the command line (visible in `ps` to every
# user on the host, and in shell history), the request is written to a 0600
# file in a private mktemp directory and passed as --cli-input-json file://…;
# the file is deleted on exit. The JSON is built by jq reading the password
# from stdin, so it is not in jq's argv either. (file:///dev/stdin does not
# work: the CLI reads the parameter file twice.)
#
# Region: the pool's region is taken from the bridge document's issuer_url.
# The secret itself is read from --region / AWS_REGION / AWS_DEFAULT_REGION /
# the CLI profile's region / us-east-1, first one set.
set -uo pipefail

: "${AWS_PAGER:=}"
export AWS_PAGER

SECRET_ID="${K8P_COGNITO_SECRET_ID:-k8-platform/base/cognito}"
GROUPS_ALLOWED="k8s-admins k8s-viewers"

usage() {
  sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'
}

die() { echo "ERROR: $*" >&2; exit 1; }

WORK="$(mktemp -d -t k8p-cognito-XXXXXX)" || die "mktemp failed"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# awsc <what> <aws args...> — run aws, stdout to $WORK/out; on failure report
# <what> and the AWS error's last line, and exit 1.
awsc() {
  local what="$1"; shift
  if aws "$@" --region "$POOL_REGION" --output json >"$WORK/out" 2>"$WORK/err"; then
    return 0
  fi
  die "$what failed: $(grep -v '^[[:space:]]*$' "$WORK/err" | tail -1)"
}

# ---- argument parsing -----------------------------------------------------
CMD="${1:-}"; [ $# -gt 0 ] && shift
case "$CMD" in
  add|remove|list) ;;
  -h|--help|help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) echo "unknown command: $CMD" >&2; usage >&2; exit 2 ;;
esac

EMAIL=""; GROUP="k8s-admins"; PW_MODE="prompt"; RESET=0
GIVEN=""; FAMILY=""; REGION_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --group) GROUP="${2:-}"; shift 2 || die "--group needs a value" ;;
    --group=*) GROUP="${1#*=}"; shift ;;
    --password-stdin) PW_MODE="stdin"; shift ;;
    --generate) PW_MODE="generate"; shift ;;
    --reset-password) RESET=1; shift ;;
    --given-name) GIVEN="${2:-}"; shift 2 || die "--given-name needs a value" ;;
    --family-name) FAMILY="${2:-}"; shift 2 || die "--family-name needs a value" ;;
    --region) REGION_ARG="${2:-}"; shift 2 || die "--region needs a value" ;;
    -h|--help) usage; exit 0 ;;
    --password|--password=*) die "--password is not accepted (it would expose the password in process arguments); use the prompt, --password-stdin or --generate" ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$EMAIL" ] || die "unexpected argument: $1"; EMAIL="$1"; shift ;;
  esac
done

if [ "$CMD" = "list" ]; then
  [ -z "$EMAIL" ] || die "list takes no <email>"
else
  [ -n "$EMAIL" ] || die "$CMD needs an <email>"
  case "$EMAIL" in *@*.*) ;; *) die "not an email address: $EMAIL" ;; esac
fi
case " $GROUPS_ALLOWED " in
  *" $GROUP "*) ;;
  *) die "--group must be one of: $GROUPS_ALLOWED (got '$GROUP')" ;;
esac

command -v aws >/dev/null 2>&1 || die "aws CLI not on PATH"
command -v jq  >/dev/null 2>&1 || die "jq not on PATH"

# ---- discovery -------------------------------------------------------------
if [ -n "$REGION_ARG" ]; then SECRET_REGION="$REGION_ARG"; REGION_SRC="--region"
elif [ -n "${AWS_REGION:-}" ]; then SECRET_REGION="$AWS_REGION"; REGION_SRC="AWS_REGION"
elif [ -n "${AWS_DEFAULT_REGION:-}" ]; then SECRET_REGION="$AWS_DEFAULT_REGION"; REGION_SRC="AWS_DEFAULT_REGION"
elif SECRET_REGION="$(aws configure get region 2>/dev/null)" && [ -n "$SECRET_REGION" ]; then REGION_SRC="CLI profile"
else SECRET_REGION="us-east-1"; REGION_SRC="default"
fi

echo "Discovery"
echo "  secret:  $SECRET_ID (region $SECRET_REGION, from $REGION_SRC)"
POOL_REGION="$SECRET_REGION"
awsc "reading the Cognito bridge document $SECRET_ID" \
  secretsmanager get-secret-value --secret-id "$SECRET_ID"
# Only issuer_url is extracted; the document also carries the Keycloak
# client secret, which this script never prints.
ISSUER="$(jq -r '.SecretString | fromjson | .issuer_url // empty' "$WORK/out" 2>/dev/null)"
[ -n "$ISSUER" ] || die "$SECRET_ID has no issuer_url (unexpected document shape)"
POOL_ID="${ISSUER##*/}"
POOL_REGION="$(printf '%s' "$ISSUER" | sed -n 's#^https://cognito-idp\.\([a-z0-9-]*\)\.amazonaws\.com/.*#\1#p')"
if [ -z "$POOL_ID" ] || [ -z "$POOL_REGION" ]; then
  die "cannot parse pool id/region from issuer_url $ISSUER"
fi
echo "  pool:    $POOL_ID"
echo "  region:  $POOL_REGION (from the pool's issuer_url)"
echo

# ---- helpers ---------------------------------------------------------------
# user_exists <username> — 0 present, 1 absent; any other error is fatal.
user_exists() {
  if aws cognito-idp admin-get-user --user-pool-id "$POOL_ID" --username "$1" \
       --region "$POOL_REGION" --output json >"$WORK/user.json" 2>"$WORK/err"; then
    return 0
  fi
  grep -q 'UserNotFoundException' "$WORK/err" && return 1
  die "admin-get-user for $1 failed: $(grep -v '^[[:space:]]*$' "$WORK/err" | tail -1)"
}

# user_groups <username> — space-separated group names (or "(none)").
user_groups() {
  awsc "admin-list-groups-for-user for $1" cognito-idp admin-list-groups-for-user \
    --user-pool-id "$POOL_ID" --username "$1"
  local g
  g="$(jq -r '[.Groups[].GroupName] | sort | join(" ")' "$WORK/out")"
  printf '%s' "${g:-(none)}"
}

gen_password() {
  # 20 chars of [A-Za-z0-9]; retried until it has every class the pool's
  # policy requires (lower, upper, digit; length >= 12).
  local p=""
  while :; do
    p="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
    case "$p" in *[a-z]*) ;; *) continue ;; esac
    case "$p" in *[A-Z]*) ;; *) continue ;; esac
    case "$p" in *[0-9]*) ;; *) continue ;; esac
    break
  done
  printf '%s' "$p"
}

PASSWORD=""
obtain_password() {
  case "$PW_MODE" in
    generate) PASSWORD="$(gen_password)" ;;
    stdin)
      IFS= read -r PASSWORD || [ -n "$PASSWORD" ] || die "--password-stdin: nothing on stdin"
      PASSWORD="${PASSWORD%$'\r'}"
      ;;
    prompt)
      { exec 3</dev/tty; } 2>/dev/null \
        || die "no terminal for the password prompt; use --password-stdin or --generate"
      local again=""
      IFS= read -rs -p "Password for $EMAIL: " PASSWORD <&3; echo >&2
      IFS= read -rs -p "Repeat password: " again <&3; echo >&2
      exec 3<&-
      [ "$PASSWORD" = "$again" ] || die "passwords do not match"
      ;;
  esac
  [ -n "$PASSWORD" ] || die "empty password"
}

set_password() {
  local req="$WORK/set-password.json"
  ( umask 077
    printf '%s' "$PASSWORD" | jq -Rs --arg pool "$POOL_ID" --arg user "$EMAIL" \
      '{UserPoolId: $pool, Username: $user, Password: ., Permanent: true}' >"$req"
  ) || die "could not build the set-password request"
  awsc "admin-set-user-password for $EMAIL" cognito-idp admin-set-user-password \
    --cli-input-json "file://$req"
  rm -f "$req"
  echo "  password: set (permanent)"
}

# verify_user <expect-group|""> — the post-change read, printed as a summary.
verify_user() {
  local expect="$1" status enabled groups
  echo
  echo "Verification (admin-get-user + admin-list-groups-for-user)"
  user_exists "$EMAIL" || die "verification: $EMAIL is NOT present in pool $POOL_ID"
  status="$(jq -r '.UserStatus' "$WORK/user.json")"
  enabled="$(jq -r '.Enabled' "$WORK/user.json")"
  groups="$(user_groups "$EMAIL")" || exit 1
  echo "  user:    $EMAIL"
  echo "  status:  $status"
  echo "  enabled: $enabled"
  echo "  groups:  $groups"
  if [ -n "$expect" ]; then
    case " $groups " in
      *" $expect "*) ;;
      *) die "verification: $EMAIL is not in $expect" ;;
    esac
  fi
  if [ "$PASSWORD_SET" -eq 1 ] && [ "$status" != "CONFIRMED" ]; then
    die "verification: status is $status after setting a permanent password (expected CONFIRMED)"
  fi
  echo "  OK"
}

# ---- commands --------------------------------------------------------------
PASSWORD_SET=0
case "$CMD" in
  add)
    echo "add $EMAIL (group $GROUP)"
    awsc "group $GROUP lookup in pool $POOL_ID" cognito-idp get-group \
      --user-pool-id "$POOL_ID" --group-name "$GROUP"
    if user_exists "$EMAIL"; then
      echo "  user:     already exists — not re-created"
      if [ "$RESET" -eq 1 ]; then
        obtain_password; set_password; PASSWORD_SET=1
      else
        echo "  password: unchanged (pass --reset-password to change it)"
        [ "$PW_MODE" = "prompt" ] || echo "  note:     --${PW_MODE/stdin/password-stdin} ignored without --reset-password"
      fi
    else
      obtain_password
      local_part="${EMAIL%%@*}"
      awsc "admin-create-user for $EMAIL" cognito-idp admin-create-user \
        --user-pool-id "$POOL_ID" --username "$EMAIL" --message-action SUPPRESS \
        --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
                          Name=given_name,Value="${GIVEN:-$local_part}" \
                          Name=family_name,Value="${FAMILY:-User}"
      echo "  user:     created"
      set_password; PASSWORD_SET=1
    fi
    awsc "admin-add-user-to-group $GROUP for $EMAIL" cognito-idp admin-add-user-to-group \
      --user-pool-id "$POOL_ID" --username "$EMAIL" --group-name "$GROUP"
    echo "  group:    member of $GROUP ensured"
    verify_user "$GROUP"
    if [ "$PW_MODE" = "generate" ] && [ "$PASSWORD_SET" -eq 1 ]; then
      echo
      echo "GENERATED PASSWORD (shown once, not stored; hand it over securely): $PASSWORD"
    fi
    ;;

  remove)
    echo "remove $EMAIL"
    if ! user_exists "$EMAIL"; then
      echo "  user:    not present in pool $POOL_ID — nothing to do"
      exit 0
    fi
    awsc "admin-delete-user for $EMAIL" cognito-idp admin-delete-user \
      --user-pool-id "$POOL_ID" --username "$EMAIL"
    echo "  user:    deleted"
    echo
    echo "Verification (admin-get-user)"
    if user_exists "$EMAIL"; then
      die "verification: $EMAIL is STILL PRESENT in pool $POOL_ID"
    fi
    echo "  verified absent: $EMAIL"
    ;;

  list)
    echo "Users in pool $POOL_ID"
    awsc "list-users" cognito-idp list-users --user-pool-id "$POOL_ID"
    cp "$WORK/out" "$WORK/users.json"
    n="$(jq '.Users | length' "$WORK/users.json")"
    if [ "$n" -eq 0 ]; then
      echo "  no users in pool $POOL_ID"
      exit 0
    fi
    printf '  %-40s %-22s %-8s %s\n' EMAIL STATUS ENABLED GROUPS
    while IFS=$'\t' read -r uname email status enabled; do
      groups="$(user_groups "$uname")" || exit 1
      printf '  %-40s %-22s %-8s %s\n' "$email" "$status" "$enabled" "$groups"
    done < <(jq -r '.Users[] | [.Username,
                     ((.Attributes // []) | map(select(.Name == "email")) | .[0].Value // "(no email)"),
                     .UserStatus, (.Enabled | tostring)] | @tsv' "$WORK/users.json")
    echo "  $n user(s)"
    ;;
esac
