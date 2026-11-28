#!/usr/bin/env bash
# .claude/beads/beads.sh — beads (bd) for this repository, on an ai-sandbox host and in a cloud
# sandbox. Installed and refreshed by ai-sandbox's `ai-sandbox-beads-repo-kit`; don't edit it
# here (changes are overwritten): change modules/beads/repo-kit/ in ai-sandbox instead.
#
# The task graph is a Dolt database on DoltHub (`sync.remote` in .beads/config.yaml), named in
# .beads/metadata.json. Two environments, decided by `detect`:
#   host   an ai-sandbox host (ai-sandbox-beads-status is installed): one shared server at
#          127.0.1.1:3307 that ai-sandbox runs and syncs every minute. This script installs,
#          starts and syncs nothing there; if the server lacks this repo's database it asks
#          ai-sandbox-beads-clone to fetch it from DoltHub.
#   local  anywhere else (a cloud sandbox): installs the pinned bd and dolt (cloud only), imports
#          the DoltHub key from $DOLTHUB_CREDS_JWK, starts a dolt sql-server on 127.0.0.1:3307,
#          clones the database with `bd bootstrap`, and runs `bd sync` every 60 s.
# Never both at once against the same DoltHub database: writes come from one place at a time.
#
# Subcommands:
#   detect          print "host" or "local"; non-zero (and set up nothing) if foreign bd/dolt
#                   processes run on a local machine
#   setup           everything the session needs (idempotent)
#   session-start   SessionStart hook: setup, then the status line and `bd ready`; never fails
#   status          one status line (the UserPromptSubmit hook)
#   diagnose        read-only report for when beads isn't working (both environments)
#   prepush-hook    PreToolUse(Bash) hook: before `git push` on a local machine, one `bd sync`
#   sync-now        one `bd sync` now (local only)
#   install | creds | start | sync-loop   the local steps, one at a time
#
# Overridable for tests: BEADS_REPO_ROOT, BEADS_DATA_DIR, BEADS_SYNC_INTERVAL,
# BEADS_DETECT_RECHECK_SECS, BEADS_DOLT_INSTALL_DIR, BEADS_AIS_BIN, BEADS_DIAG_HOSTS, HOME.
set -uo pipefail

KIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT="${BEADS_REPO_ROOT:-$(cd "$KIT_DIR/../.." && pwd)}"
DATA_DIR="${BEADS_DATA_DIR:-$HOME/.beads-dolt}"
SERVER_PID="$DATA_DIR/server.pid"
LOOP_PID="$DATA_DIR/sync-loop.pid"
SERVER_LOG="$DATA_DIR/server.log"
LOOP_LOG="$DATA_DIR/sync-loop.log"
SYNC_LOCK="$DATA_DIR/sync.lock"
STATUS_FILE="$ROOT/.beads/sync-loop.status"
PORT=3307
LOCAL_HOST=127.0.0.1
HOST_HOST=127.0.1.1
SYNC_INTERVAL="${BEADS_SYNC_INTERVAL:-60}"
RECHECK_SECS="${BEADS_DETECT_RECHECK_SECS:-5}"
DOLT_INSTALL_DIR="${BEADS_DOLT_INSTALL_DIR:-/usr/local/bin}"
STALE_SECS=180
AIS_BIN="${BEADS_AIS_BIN:-$HOME/.local/bin}"
AIS_STATE="$HOME/.local/state/ai-sandbox"

# Pins: written by ai-sandbox-beads-repo-kit from ai-sandbox's versions.toml, the same bd the
# host runs (bd refuses a database migrated by a newer bd).
# shellcheck disable=SC1091
. "$KIT_DIR/versions.env"

# bd must never start or stop a server itself, and never adopt the git origin (GitHub) as its
# Dolt remote. .claude/settings.json sets the same for the agent's shell.
export BEADS_DOLT_SERVER_MODE=1 BEADS_DOLT_AUTO_START=0 BD_NO_REMOTE_ADOPT=1

say() { printf 'beads: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

on_host() { [ -x "$AIS_BIN/ai-sandbox-beads-status" ]; }

# bd needs the port too: on the host it is in ~/.config/bd/config.yaml, but nowhere else, and
# without it `bd bootstrap` dials port 0 (found in the first cloud run, 2026-11-28). The port file
# below gives it to the agent's own bd commands as well.
export BEADS_DOLT_SERVER_PORT="$PORT"
if on_host; then
    export BEADS_DOLT_SERVER_HOST="$HOST_HOST"
else
    export BEADS_DOLT_SERVER_HOST="$LOCAL_HOST"
fi

meta() { # <key> from .beads/metadata.json
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "$ROOT/.beads/metadata.json" 2>/dev/null | head -n 1
}
db_name() { meta dolt_database; }

bd_ok() { (cd "$ROOT" && bd status --json) >/dev/null 2>&1; }

bd_version() { bd version 2>/dev/null | sed -n 's/^bd version \([0-9][^ ]*\).*/\1/p'; }

# Per-clone settings git can't carry: bd warns unless .beads is 0700, and asks for a beads.role
# (only used for contributor routing, which is off; this repo's owner maintains it).
fix_clone() {
    [ -d "$ROOT/.beads" ] && chmod 700 "$ROOT/.beads" 2>/dev/null
    if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 &&
        [ -z "$(git -C "$ROOT" config --get beads.role 2>/dev/null)" ]; then
        git -C "$ROOT" config beads.role maintainer 2>/dev/null
    fi
    return 0
}

pid_alive() { # <pidfile>
    [ -f "$1" ] || return 1
    local p
    p=$(cat "$1" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# SELECT 1 against host:port (dolt client if present, else a TCP connect).
probe() { # <host> <port>
    if command -v dolt >/dev/null 2>&1; then
        (cd / && dolt --host "$1" --port "$2" --no-tls -u root -p "" \
            sql -q "SELECT 1") >/dev/null 2>&1
    else
        (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null
    fi
}

# ---- detect ---------------------------------------------------------------

own_pids() {
    local f
    for f in "$SERVER_PID" "$LOOP_PID"; do
        [ -f "$f" ] && cat "$f" 2>/dev/null
    done
}

# A process is ours if it, or an ancestor, is named in our PID files. Zombies don't count.
is_ours() { # <pid>
    local p="$1" own stat _
    own=" $(own_pids | tr '\n' ' ') "
    stat=$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ')
    case "$stat" in Z*) return 0 ;; esac
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || return 1
        case "$own" in *" $p "*) return 0 ;; esac
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    done
    return 1
}

foreign() { # <name>: PIDs of foreign processes with that exact name
    local p
    for p in $(pgrep -x "$1" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        is_ours "$p" || printf '%s\n' "$p"
    done
}

foreign_report() {
    local dolts bds1 bds p
    dolts=$(foreign dolt)
    bds1=$(foreign bd)
    bds=""
    if [ -n "$bds1" ]; then
        sleep "$RECHECK_SECS"
        # Only bd processes still alive after the re-check are foreign; hook commands are short.
        for p in $(foreign bd); do
            case " $(echo "$bds1" | tr '\n' ' ') " in *" $p "*) bds="$bds $p" ;; esac
        done
    fi
    for p in $dolts $bds; do
        ps -o pid=,args= -p "$p" 2>/dev/null || echo "$p"
    done
}

cmd_detect() {
    if on_host; then
        echo host
        return 0
    fi
    local procs
    procs=$(foreign_report)
    if [ -n "$procs" ]; then
        say "FOREIGN bd/dolt PROCESSES ARE RUNNING: setting up nothing (never start a second server)."
        printf '%s\n' "$procs" | sed 's/^/beads:   /' >&2
        say "beads is UNAVAILABLE this session until the owner says what these are."
        return 1
    fi
    echo local
}

# ---- host -----------------------------------------------------------------

host_setup() {
    command -v bd >/dev/null 2>&1 || die "ai-sandbox host but no bd on PATH: run ai-sandbox setup"
    local first db
    first=$("$AIS_BIN/ai-sandbox-beads-status" 2>/dev/null | head -n 1)
    case "$first" in
        "STOPPED ON PURPOSE"*)
            say "$first"
            die "the host's beads server is stopped on purpose; use the beads-onboarding skill (only the owner restarts it)" ;;
        running*) ;;
        *) die "the host's beads server isn't running ($first); use the beads-onboarding skill" ;;
    esac
    bd_ok && return 0
    db=$(db_name)
    [ -n "$db" ] || die "no dolt_database in .beads/metadata.json: onboard this repo (beads-onboarding skill)"
    say "database $db isn't on the host's server yet: cloning it from DoltHub"
    "$AIS_BIN/ai-sandbox-beads-clone" "$db" "$(meta project_id)" >&2 ||
        die "ai-sandbox-beads-clone $db failed (above); use the beads-onboarding skill"
    bd_ok || die "bd still can't read $db after the clone; use the beads-onboarding skill"
}

host_status() {
    local json ready prog first extra last now
    first=$("$AIS_BIN/ai-sandbox-beads-status" 2>/dev/null | head -n 1)
    case "$first" in
        "STOPPED ON PURPOSE"*)
            echo "beads: UNAVAILABLE !! $first (beads-onboarding skill; only the owner restarts it)"
            return 0 ;;
    esac
    json=$(cd "$ROOT" && bd status --json 2>/dev/null)
    if [ -z "$json" ]; then
        echo "beads: UNAVAILABLE: bd can't read $(db_name) on the host's server ($first); run: bash .claude/beads/beads.sh setup"
        return 0
    fi
    ready=$(printf '%s' "$json" | sed -n 's/.*"ready_issues"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
    prog=$(printf '%s' "$json" | sed -n 's/.*"in_progress_issues"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
    last=$(sed -n 's/.*"last_success"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$AIS_STATE/beads-sync.state" 2>/dev/null)
    now=$(date +%s)
    if [ -n "$last" ]; then
        extra="host-sync ok $((now - last))s ago"
        [ $((now - last)) -gt "$STALE_SECS" ] && extra="$extra !! STALE (ai-sandbox-beads-status)"
    else
        extra="host-sync: none yet"
    fi
    [ "$(bd_version)" = "$BD_VERSION" ] ||
        extra="$extra !! host bd $(bd_version), the repo kit pins $BD_VERSION: refresh the kit (ai-sandbox-beads-repo-kit)"
    echo "beads: ready=${ready:-?} in_progress=${prog:-?} $extra"
}

# ---- local: install -------------------------------------------------------

cmd_install() {
    local have
    have=$(bd_version)
    if [ "$have" != "$BD_VERSION" ]; then
        say "installing @beads/bd@$BD_VERSION (found: ${have:-none})"
        npm install -g "@beads/bd@$BD_VERSION" >/dev/null 2>&1 ||
            die "npm install -g @beads/bd@$BD_VERSION failed"
    fi
    have=$(dolt version 2>/dev/null | sed -n 's/^dolt version \([0-9][^ ]*\).*/\1/p' | head -n 1)
    if [ "$have" != "$DOLT_VERSION" ]; then
        say "installing dolt $DOLT_VERSION (found: ${have:-none})"
        local tmp
        tmp=$(mktemp -d) || die "mktemp failed"
        curl -fsSL -o "$tmp/dolt.tar.gz" \
            "https://github.com/dolthub/dolt/releases/download/v$DOLT_VERSION/dolt-linux-amd64.tar.gz" ||
            { rm -rf "$tmp"; die "dolt download failed"; }
        if ! echo "$DOLT_SHA256  $tmp/dolt.tar.gz" | sha256sum -c - >/dev/null 2>&1; then
            rm -rf "$tmp"
            die "dolt tarball SHA-256 mismatch: refusing to install"
        fi
        tar -xzf "$tmp/dolt.tar.gz" -C "$tmp" &&
            install -m 0755 "$tmp/dolt-linux-amd64/bin/dolt" "$DOLT_INSTALL_DIR/dolt" ||
            { rm -rf "$tmp"; die "dolt install failed"; }
        rm -rf "$tmp"
    fi
    say "bd $(bd_version), dolt $(dolt version 2>/dev/null | awk 'NR==1{print $3}')"
}

# ---- local: creds ---------------------------------------------------------

cmd_creds() {
    command -v dolt >/dev/null 2>&1 || die "dolt not installed"
    # Either name: DOLTHUB_CREDS_JWK (cloud environments) or DOLT_CREDS_JWK (ai-sandbox's name).
    local key="${DOLTHUB_CREDS_JWK:-${DOLT_CREDS_JWK:-}}"
    if [ -z "$key" ]; then
        die "no DoltHub key (DOLTHUB_CREDS_JWK unset in this environment): beads unavailable this session"
    fi
    local name email
    name=$(git -C "$ROOT" config user.name 2>/dev/null || true)
    email=$(git -C "$ROOT" config user.email 2>/dev/null || true)
    dolt config --global --set user.name "${name:-beads-agent}" >/dev/null 2>&1 ||
        dolt config --global --add user.name "${name:-beads-agent}" >/dev/null 2>&1
    dolt config --global --set user.email "${email:-beads-agent@localhost}" >/dev/null 2>&1 ||
        dolt config --global --add user.email "${email:-beads-agent@localhost}" >/dev/null 2>&1
    dolt config --global --set metrics.disabled true >/dev/null 2>&1 ||
        dolt config --global --add metrics.disabled true >/dev/null 2>&1
    if dolt creds check >/dev/null 2>&1; then
        say "DoltHub key already active"
        return 0
    fi
    # Never echo the key: it goes to dolt's stdin only, output discarded.
    printf '%s' "$key" | dolt creds import --no-profile >/dev/null 2>&1 ||
        die "dolt creds import failed"
    dolt creds check >/dev/null 2>&1 || die "DoltHub rejected the key (dolt creds check failed)"
    say "DoltHub key imported and accepted"
}

# ---- local: start ---------------------------------------------------------

cmd_start() {
    command -v dolt >/dev/null 2>&1 || die "dolt not installed"
    command -v bd >/dev/null 2>&1 || die "bd not installed"
    local db
    db=$(db_name)
    [ -n "$db" ] || die "no dolt_database in .beads/metadata.json"
    mkdir -p "$DATA_DIR" || die "cannot create $DATA_DIR"
    if pid_alive "$SERVER_PID" && probe "$LOCAL_HOST" "$PORT"; then
        say "server already running (pid $(cat "$SERVER_PID"))"
    else
        # Launch dolt directly (not in a subshell) so $! is the server's own PID.
        nohup dolt sql-server --data-dir "$DATA_DIR" --host "$LOCAL_HOST" \
            --port "$PORT" >"$SERVER_LOG" 2>&1 </dev/null &
        echo $! >"$SERVER_PID"
        for _ in $(seq 1 30); do
            probe "$LOCAL_HOST" "$PORT" && break
            sleep 1
        done
        probe "$LOCAL_HOST" "$PORT" || die "server did not answer on $LOCAL_HOST:$PORT (see $SERVER_LOG)"
        say "server started (pid $(cat "$SERVER_PID"))"
    fi
    # bd reads the server's port from here (k8s-platform's script did this; the kit had dropped it).
    echo "$PORT" >"$ROOT/.beads/dolt-server.port"
    if [ ! -d "$DATA_DIR/$db" ]; then
        # `bd bootstrap`, never a plain `dolt clone`: a dolt clone lacks bd's machine-local
        # tables (leases, events, wisps, ...) and bd can't open it.
        say "cloning $db from sync.remote via bd bootstrap"
        (cd "$ROOT" && bd bootstrap --yes) >>"$SERVER_LOG" 2>&1 ||
            die "bd bootstrap failed (see $SERVER_LOG)"
    fi
    bd_ok || die "bd cannot read $db after start"
}

# ---- local: sync ----------------------------------------------------------

sync_once() {
    local rc
    mkdir -p "$DATA_DIR"
    if command -v flock >/dev/null 2>&1; then
        (cd "$ROOT" && flock -w 120 "$SYNC_LOCK" bd sync)
    else
        (cd "$ROOT" && bd sync)
    fi
    rc=$?
    printf '%s %s\n' "$rc" "$(date +%s)" >"$STATUS_FILE"
    return "$rc"
}

cmd_loop() { # internal: the background loop body
    while :; do
        sync_once
        sleep "$SYNC_INTERVAL"
    done
}

cmd_sync_loop() {
    if pid_alive "$LOOP_PID"; then
        say "sync loop already running (pid $(cat "$LOOP_PID"))"
        return 0
    fi
    mkdir -p "$DATA_DIR" || die "cannot create $DATA_DIR"
    nohup bash "$KIT_DIR/beads.sh" _loop >>"$LOOP_LOG" 2>&1 </dev/null &
    echo $! >"$LOOP_PID"
    say "sync loop started (pid $(cat "$LOOP_PID"), every ${SYNC_INTERVAL}s)"
}

cmd_sync_now() {
    on_host && { say "ai-sandbox host: the host syncs every minute; nothing to do"; return 0; }
    sync_once >>"$LOOP_LOG" 2>&1
}

local_status() {
    local json ready prog extra code ts age
    json=$(cd "$ROOT" && bd status --json 2>/dev/null)
    if [ -z "$json" ]; then
        local why="server not answering"
        [ -n "${DOLTHUB_CREDS_JWK:-${DOLT_CREDS_JWK:-}}" ] || why="no DoltHub key (DOLTHUB_CREDS_JWK unset)"
        echo "beads: UNAVAILABLE: $why; run: bash .claude/beads/beads.sh setup"
        return 0
    fi
    ready=$(printf '%s' "$json" | sed -n 's/.*"ready_issues"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
    prog=$(printf '%s' "$json" | sed -n 's/.*"in_progress_issues"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
    if [ -f "$STATUS_FILE" ]; then
        read -r code ts <"$STATUS_FILE"
        age=$(( $(date +%s) - ${ts:-0} ))
        extra="last-sync=$code ${age}s ago"
        case "$code" in
            1) extra="$extra !! SYNC ERROR: see $LOOP_LOG" ;;
            2) extra="$extra !! MERGE CONFLICT, nothing pushed: resolve by hand" ;;
            4) extra="$extra !! STUCK WORKING SET, nothing pushed: operator must clear" ;;
        esac
        [ "$age" -gt "$STALE_SECS" ] && extra="$extra !! STALE: is the sync loop running?"
    else
        extra="last-sync=none"
    fi
    echo "beads: ready=${ready:-?} in_progress=${prog:-?} $extra"
}

cmd_status() {
    if ! command -v bd >/dev/null 2>&1; then
        echo "beads: UNAVAILABLE: bd not installed (see session-start output)"
        return 0
    fi
    if on_host; then
        host_status
        return 0
    fi
    local have
    have=$(bd_version)
    if [ "$have" != "$BD_VERSION" ]; then
        echo "beads: UNAVAILABLE: bd ${have:-?} installed, .claude/beads/versions.env pins $BD_VERSION"
        return 0
    fi
    local_status
}

# ---- diagnose (read-only) -------------------------------------------------

# Everything needed to say why beads isn't working, for either environment. Changes nothing;
# never prints the DoltHub key. Every section prints something, "NONE" when empty.
section() { printf '\n== %s\n' "$1"; }
show() { # <text>: the text, or NONE
    if [ -n "$1" ]; then printf '%s\n' "$1"; else echo NONE; fi
}
code_meaning() {
    case "$1" in
        0) echo "synced" ;; 1) echo "ERROR (see sync-loop.log)" ;;
        2) echo "MERGE CONFLICT, nothing pushed" ;; 3) echo "transient (network?), retried" ;;
        4) echo "STUCK WORKING SET, nothing pushed" ;; *) echo "unknown" ;;
    esac
}

cmd_diagnose() {
    local db env have_bd have_dolt
    db=$(db_name)
    if on_host; then env=host; else env=local; fi
    echo "beads diagnose: repo $ROOT, database ${db:-NONE (no dolt_database in .beads/metadata.json)}, environment $env"
    have_bd=$(bd_version)
    have_dolt=$(dolt version 2>/dev/null | sed -n 's/^dolt version \([0-9][^ ]*\).*/\1/p' | head -n 1)
    section "versions (installed / pinned in .claude/beads/versions.env)"
    echo "bd   ${have_bd:-not installed} / $BD_VERSION$([ "$have_bd" = "$BD_VERSION" ] || echo '  !! MISMATCH')"
    echo "dolt ${have_dolt:-not installed} / $DOLT_VERSION$([ "$have_dolt" = "$DOLT_VERSION" ] || echo '  !! MISMATCH')"
    section "repo files"
    echo ".beads mode $(stat -c %a "$ROOT/.beads" 2>/dev/null || echo missing); beads.role $(git -C "$ROOT" config --get beads.role 2>/dev/null || echo unset)"
    echo "uncommitted changes to beads files: $(git -C "$ROOT" status --short -- .beads .claude/beads .claude/settings.json 2>/dev/null | tr '\n' ';' | grep . || echo NONE)"
    if [ -f "$ROOT/.beads/.env" ]; then
        echo ".beads/.env (overrides metadata.json): $(grep -v '^#' "$ROOT/.beads/.env" | tr '\n' ' ')"
    else
        echo ".beads/.env: none (metadata.json decides)"
    fi
    section "bd status"
    show "$( (cd "$ROOT" && bd status --json 2>&1) | head -n 15)"
    if [ "$env" = host ]; then
        section "host: ai-sandbox-beads-status"
        show "$("$AIS_BIN/ai-sandbox-beads-status" "$ROOT" 2>&1)"
        section "host: sync log, this database and halts (last 15)"
        show "$(grep -E " ${db:-.} |HALT|RESUME" "$AIS_STATE/beads-sync.log" 2>/dev/null | tail -n 15)"
        echo
        echo "next: the beads skill's \"Diagnosing\" section (host); resolving halts is in the beads-onboarding skill"
        return 0
    fi
    section "local: environment"
    echo "CLAUDE_CODE_REMOTE=${CLAUDE_CODE_REMOTE:-unset}; DoltHub key in env: $([ -n "${DOLTHUB_CREDS_JWK:-${DOLT_CREDS_JWK:-}}" ] && echo yes || echo NO)"
    if command -v dolt >/dev/null 2>&1; then
        echo "dolt creds check: $(dolt creds check >/dev/null 2>&1 && echo ok || echo FAILED)"
    fi
    for h in ${BEADS_DIAG_HOSTS-doltremoteapi.dolthub.com registry.npmjs.org github.com}; do
        # shellcheck disable=SC2016  # $0 is expanded by the inner bash
        echo "reach $h:443: $(timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/443"' "$h" 2>/dev/null && echo ok || echo FAILED)"
    done
    section "local: processes"
    echo "server pid $(cat "$SERVER_PID" 2>/dev/null || echo none): $(pid_alive "$SERVER_PID" && echo alive || echo NOT RUNNING); answers on $LOCAL_HOST:$PORT: $(probe "$LOCAL_HOST" "$PORT" && echo yes || echo NO)"
    echo "sync loop pid $(cat "$LOOP_PID" 2>/dev/null || echo none): $(pid_alive "$LOOP_PID" && echo alive || echo NOT RUNNING)"
    echo "foreign bd/dolt: $(RECHECK_SECS=0 foreign_report | tr '\n' ';' | sed 's/;$//' | grep . || echo NONE)"
    section "local: last sync (.beads/sync-loop.status)"
    if [ -f "$STATUS_FILE" ]; then
        local code ts
        read -r code ts <"$STATUS_FILE"
        echo "code $code ($(code_meaning "$code")), $(( $(date +%s) - ${ts:-0} ))s ago"
    else
        echo NONE
    fi
    section "local: database"
    echo "data dir $DATA_DIR/$db: $([ -d "$DATA_DIR/$db" ] && echo present || echo MISSING)"
    if probe "$LOCAL_HOST" "$PORT" && [ -n "$db" ]; then
        show "$( (cd / && dolt --host "$LOCAL_HOST" --port "$PORT" --no-tls -u root -p "" --use-db "$db" sql -r csv \
            -q "SELECT name, url FROM dolt_remotes" 2>&1) | sed 's/^/remote: /')"
    fi
    section "local: server.log (last 10)"
    show "$(tail -n 10 "$SERVER_LOG" 2>/dev/null)"
    section "local: sync-loop.log (last 10)"
    show "$(tail -n 10 "$LOOP_LOG" 2>/dev/null)"
    echo
    echo "next: the beads skill's \"Diagnosing\" section (cloud sandbox)"
}

# ---- setup and hooks ------------------------------------------------------

cmd_setup() {
    local mode
    mode=$(cmd_detect) || return 1
    fix_clone
    if [ "$mode" = host ]; then
        host_setup
        return
    fi
    if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
        cmd_install || return 1
    fi
    cmd_creds || return 1
    cmd_start || return 1
    cmd_sync_loop || return 1
}

cmd_session_start() {
    # A SessionStart hook's stdout is what the session sees; stderr isn't. So setup's messages go
    # to a file, shown on stdout when it fails (a silent failure left the first cloud run guessing).
    local out
    out=$(mktemp)
    if (cmd_setup) >"$out" 2>&1; then
        rm -f "$out"
        if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
            printf 'export BEADS_DOLT_SERVER_HOST=%s BEADS_DOLT_SERVER_PORT=%s\n' \
                "$BEADS_DOLT_SERVER_HOST" "$PORT" >>"$CLAUDE_ENV_FILE"
        fi
        # One status line and the ready queue (not `bd prime`: its generic session-close text
        # conflicts with repos' own rules).
        cmd_status
        (cd "$ROOT" && bd ready 2>/dev/null | head -n 20) || true
    else
        echo "beads: setup FAILED, no task graph this session. Setup said:"
        sed 's/^/  /' "$out"
        rm -f "$out"
        cmd_status
        echo "beads: next: bash .claude/beads/beads.sh diagnose, then the Diagnosing section of the beads skill"
    fi
    return 0
}

# PreToolUse(Bash): before a `git push` on a local machine, one `bd sync`, so code and task state
# leave the sandbox together.
#   sync 0 -> allow; 3 (transient) -> allow with a warning; 1/2/4 -> block (exit 2)
#   beads unavailable -> allow with a warning; ai-sandbox host -> allow (the host syncs)
cmd_prepush_hook() {
    local input cmd line rc
    input=$(cat)
    if command -v jq >/dev/null 2>&1; then
        cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
    else
        cmd=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
    fi
    case "$cmd" in
        *"git push"*|*"git  push"*) ;;
        *) return 0 ;;
    esac
    [ -d "$ROOT/.beads" ] || return 0
    on_host && return 0
    line=$(cmd_status 2>/dev/null)
    case "$line" in
        "beads: ready="*) ;;
        *) say "${line:-beads unavailable}; pushing code without a beads sync."
           return 0 ;;
    esac
    sync_once >>"$LOOP_LOG" 2>&1
    rc=$?
    case "$rc" in
        0) return 0 ;;
        3) say "bd sync transient failure (3); the background loop retries. Allowing the push."; return 0 ;;
        2) say "bd sync hit a MERGE CONFLICT (2), nothing pushed. Resolve it by hand before pushing code." ;;
        4) say "bd sync STUCK WORKING SET (4), nothing pushed. Clear it before pushing code." ;;
        *) say "bd sync FAILED ($rc). Fix it before pushing code; log: $LOOP_LOG" ;;
    esac
    return 2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    sub="${1:-}"
    case "$sub" in
        install|creds|start|sync-loop)
            mode=$(cmd_detect) || exit 1
            [ "$mode" = host ] && die "ai-sandbox host: '$sub' is never run here (the host runs the server)"
            ;;
    esac
    case "$sub" in
        detect) cmd_detect ;;
        install) cmd_install ;;
        creds) cmd_creds ;;
        start) cmd_start ;;
        sync-loop) cmd_sync_loop ;;
        sync-now) cmd_sync_now ;;
        _loop) cmd_loop ;;
        status) cmd_status ;;
        setup) cmd_setup ;;
        session-start) cmd_session_start ;;
        prepush-hook) cmd_prepush_hook ;;
        diagnose) cmd_diagnose ;;
        *) printf 'usage: %s {detect|setup|session-start|status|diagnose|prepush-hook|sync-now|install|creds|start|sync-loop}\n' "$0" >&2; exit 2 ;;
    esac
fi
