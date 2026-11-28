#!/usr/bin/env bash
# beads-server.sh — run beads (bd) in server mode against a local
# dolt sql-server, synced with the DoltHub remote in .beads/config.yaml.
#
# Design and rationale: ai/beads-dolthub.md. Migration record:
# ai/beads-dolthub-migration-handoff.md.
#
# Subcommands (each idempotent):
#   detect     print "normal" or "shared"; non-zero exit (and set up nothing)
#              when a foreign bd/dolt is running or the shared server is broken
#   install    pinned bd (npm) and dolt (checksummed tarball), from versions.env
#   creds      dolt identity + DoltHub key from $DOLTHUB_CREDS_JWK
#   start      local dolt sql-server; `bd bootstrap` the database if missing
#   sync-loop  background `bd sync` every 60 s (PID-file guarded)
#   sync-now   one `bd sync` now (the pre-`git push` hook uses this)
#   status     one status line for the prompt hook
#   setup      detect, then (normal path) install*, creds, start, sync-loop
#              (*install only when CLAUDE_CODE_REMOTE=true)
#
# Overridable for tests: BEADS_REPO_ROOT, BEADS_DATA_DIR, BEADS_SYNC_INTERVAL,
# BEADS_DETECT_RECHECK_SECS, BEADS_DOLT_INSTALL_DIR, HOME.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT="${BEADS_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DATA_DIR="${BEADS_DATA_DIR:-/home/user/.beads-dolt}"
SERVER_PID="$DATA_DIR/server.pid"
LOOP_PID="$DATA_DIR/sync-loop.pid"
SERVER_LOG="$DATA_DIR/server.log"
LOOP_LOG="$DATA_DIR/sync-loop.log"
SYNC_LOCK="$DATA_DIR/sync.lock"
STATUS_FILE="$ROOT/.beads/sync-loop.status"
PORT=3307
LOCAL_HOST=127.0.0.1
# The shared sandbox's server listens on 127.0.1.1, not 127.0.0.1. This is
# intentional (owner, 2026-11-28).
SHARED_HOST=127.0.1.1
SYNC_INTERVAL="${BEADS_SYNC_INTERVAL:-60}"
RECHECK_SECS="${BEADS_DETECT_RECHECK_SECS:-5}"
DOLT_INSTALL_DIR="${BEADS_DOLT_INSTALL_DIR:-/usr/local/bin}"
STALE_SECS=180

MARKER_DIR="$HOME/.local/state/ai-sandbox"
SHARED_LOG="$MARKER_DIR/beads-sync.log"
SHARED_STATE="$MARKER_DIR/beads-sync.state"

# Pins: versions.env is the single source of truth.
# shellcheck disable=SC1091
. "$ROOT/versions.env"

# bd must never start/stop a server itself, and must never adopt the git
# origin (GitHub) as its Dolt remote. .claude/settings.json sets the same.
export BEADS_DOLT_SERVER_MODE=1 BEADS_DOLT_AUTO_START=0 BD_NO_REMOTE_ADOPT=1

say() { printf 'beads-server: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

# bd's server host: the shared one when the marker says so.
if [ -d "$MARKER_DIR" ]; then
    export BEADS_DOLT_SERVER_HOST="$SHARED_HOST"
else
    export BEADS_DOLT_SERVER_HOST="$LOCAL_HOST"
fi

db_name() {
    sed -n 's/.*"dolt_database"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$ROOT/.beads/metadata.json" 2>/dev/null | head -n 1
}

pid_alive() { # <pidfile>
    [ -f "$1" ] || return 1
    local p
    p=$(cat "$1" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# SELECT 1 against host:port. Uses the dolt client when present; on a shared
# sandbox without dolt, falls back to a TCP connect.
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

# A process is ours if it, or any ancestor, is named in our PID files
# (the server's own dolt children, the loop's `bd sync`). Zombies don't count.
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

foreign() { # <name> — PIDs of foreign processes with that exact name
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
        # Only bd processes still alive after the re-check are foreign;
        # short-lived hook commands are expected.
        for p in $(foreign bd); do
            case " $(echo "$bds1" | tr '\n' ' ') " in *" $p "*) bds="$bds $p" ;; esac
        done
    fi
    for p in $dolts $bds; do
        ps -o pid=,args= -p "$p" 2>/dev/null || echo "$p"
    done
}

cmd_detect() {
    if [ ! -d "$MARKER_DIR" ]; then
        local procs
        procs=$(foreign_report)
        if [ -n "$procs" ]; then
            say "FOREIGN bd/dolt PROCESSES ARE RUNNING — setting up nothing (owner rule: never start a second server)."
            printf '%s\n' "$procs" | sed 's/^/beads-server:   /' >&2
            say "beads is UNAVAILABLE this session until the owner says what these are."
            return 1
        fi
        echo normal
        return 0
    fi
    local up=1 halted=1
    probe "$SHARED_HOST" "$PORT" && up=0
    grep -q 'beads-sync-HALTED' "$SHARED_STATE" 2>/dev/null && halted=0
    if [ "$up" -eq 0 ] && [ "$halted" -ne 0 ]; then
        echo shared
        return 0
    fi
    say "SHARED SANDBOX BEADS CONFIG IS BROKEN — setting up nothing, not repairing."
    [ "$up" -ne 0 ] && say "  no server answers at $SHARED_HOST:$PORT"
    [ "$halted" -eq 0 ] && say "  $SHARED_STATE has a beads-sync-HALTED record"
    say "  see $SHARED_LOG"
    return 1
}

# ---- install --------------------------------------------------------------

cmd_install() {
    local have
    have=$(bd version 2>/dev/null | sed -n 's/^bd version \([0-9][^ ]*\).*/\1/p')
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
            die "dolt tarball SHA-256 mismatch — refusing to install"
        fi
        tar -xzf "$tmp/dolt.tar.gz" -C "$tmp" &&
            install -m 0755 "$tmp/dolt-linux-amd64/bin/dolt" "$DOLT_INSTALL_DIR/dolt" ||
            { rm -rf "$tmp"; die "dolt install failed"; }
        rm -rf "$tmp"
    fi
    say "bd $(bd version 2>/dev/null | awk '{print $3}'), dolt $(dolt version 2>/dev/null | awk 'NR==1{print $3}')"
}

# ---- creds ----------------------------------------------------------------

cmd_creds() {
    command -v dolt >/dev/null 2>&1 || die "dolt not installed"
    if [ -z "${DOLTHUB_CREDS_JWK:-}" ]; then
        die "no DoltHub key (DOLTHUB_CREDS_JWK unset): beads unavailable this session"
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
    # Never echo the variable: it goes to dolt's stdin only, output discarded.
    printf '%s' "$DOLTHUB_CREDS_JWK" | dolt creds import --no-profile >/dev/null 2>&1 ||
        die "dolt creds import failed"
    dolt creds check >/dev/null 2>&1 || die "DoltHub rejected the key (dolt creds check failed)"
    say "DoltHub key imported and accepted"
}

# ---- start ----------------------------------------------------------------

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
        # Launch dolt directly (not inside `cd && …` or a subshell) so $! is
        # the server's own PID.
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
    echo "$PORT" >"$ROOT/.beads/dolt-server.port"
    if [ ! -d "$DATA_DIR/$db" ]; then
        # `bd bootstrap`, never a plain `dolt clone`: a dolt clone lacks bd's
        # clone-local tables (leases, events, wisps, …) and bd cannot open it.
        say "cloning $db from sync.remote via bd bootstrap"
        (cd "$ROOT" && bd bootstrap --yes) >>"$SERVER_LOG" 2>&1 ||
            die "bd bootstrap failed (see $SERVER_LOG)"
    fi
    (cd "$ROOT" && bd status --json) >/dev/null 2>&1 || die "bd cannot read $db after start"
}

# ---- sync -----------------------------------------------------------------

sync_once() {
    local rc
    if command -v flock >/dev/null 2>&1; then
        mkdir -p "$DATA_DIR"
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
    nohup bash "$SCRIPT_DIR/beads-server.sh" _loop >>"$LOOP_LOG" 2>&1 </dev/null &
    echo $! >"$LOOP_PID"
    say "sync loop started (pid $(cat "$LOOP_PID"), every ${SYNC_INTERVAL}s)"
}

cmd_sync_now() {
    sync_once >>"$LOOP_LOG" 2>&1
}

# ---- status ---------------------------------------------------------------

cmd_status() {
    local json ready prog extra="" have
    if ! command -v bd >/dev/null 2>&1; then
        echo "beads: UNAVAILABLE — bd not installed (see session-start output)"
        return 0
    fi
    have=$(bd version 2>/dev/null | sed -n 's/^bd version \([0-9][^ ]*\).*/\1/p')
    if [ "$have" != "$BD_VERSION" ]; then
        echo "beads: UNAVAILABLE — bd ${have:-?} installed, versions.env pins $BD_VERSION"
        return 0
    fi
    json=$(cd "$ROOT" && bd status --json 2>/dev/null)
    if [ -z "$json" ]; then
        local why="server not answering"
        [ -d "$MARKER_DIR" ] || [ -n "${DOLTHUB_CREDS_JWK:-}" ] || why="no DoltHub key (DOLTHUB_CREDS_JWK unset)"
        echo "beads: UNAVAILABLE — $why; run: bash scripts/beads-server.sh setup"
        return 0
    fi
    ready=$(printf '%s' "$json" | sed -n 's/.*"ready_issues"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
    prog=$(printf '%s' "$json" | sed -n 's/.*"in_progress_issues"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
    if [ -d "$MARKER_DIR" ]; then
        local last
        last=$(tail -n 1 "$SHARED_STATE" 2>/dev/null | cut -c1-80)
        extra="shared-sync=${last:-none}"
        grep -q 'beads-sync-HALTED' "$SHARED_STATE" 2>/dev/null &&
            extra="$extra !! SHARED SYNC HALTED — see $SHARED_LOG"
    else
        local code ts age
        if [ -f "$STATUS_FILE" ]; then
            read -r code ts <"$STATUS_FILE"
            age=$(( $(date +%s) - ${ts:-0} ))
            extra="last-sync=$code ${age}s ago"
            case "$code" in
                1) extra="$extra !! SYNC ERROR — see $LOOP_LOG" ;;
                2) extra="$extra !! MERGE CONFLICT, nothing pushed — resolve by hand" ;;
                4) extra="$extra !! STUCK WORKING SET, nothing pushed — operator must clear" ;;
            esac
            [ "$age" -gt "$STALE_SECS" ] && extra="$extra !! STALE — is the sync loop running?"
        else
            extra="last-sync=none"
        fi
    fi
    echo "beads: ready=${ready:-?} in_progress=${prog:-?} $extra"
}

# ---- setup (session start) ------------------------------------------------

cmd_setup() {
    local mode
    mode=$(cmd_detect) || return 1
    if [ "$mode" = shared ]; then
        command -v bd >/dev/null 2>&1 || die "shared sandbox but no bd on PATH — not installing one"
        echo "$PORT" >"$ROOT/.beads/dolt-server.port"
        say "shared sandbox: using the server at $SHARED_HOST:$PORT; it syncs itself"
        # The database is part of this repo: if the shared server does not
        # hold it yet, clone it there from sync.remote. The clone runs inside
        # the shared server, with that server's DoltHub credentials; if it
        # has none, bd's error is shown and setup fails.
        if ! (cd "$ROOT" && bd status --json) >/dev/null 2>&1; then
            local out
            say "database $(db_name) not on the shared server — cloning it with bd bootstrap"
            if ! out=$(cd "$ROOT" && bd bootstrap --yes 2>&1); then
                printf '%s\n' "$out" | tail -n 20 | sed 's/^/beads-server:   /' >&2
                die "bd bootstrap into the shared server FAILED (output above)"
            fi
            (cd "$ROOT" && bd status --json) >/dev/null 2>&1 ||
                die "bd still cannot read $(db_name) on the shared server after bootstrap"
            say "database $(db_name) cloned into the shared server"
        fi
        return 0
    fi
    if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
        cmd_install || return 1
    fi
    cmd_creds || return 1
    cmd_start || return 1
    cmd_sync_loop || return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    sub="${1:-}"
    # detect runs before every other subcommand that sets anything up.
    case "$sub" in
        install|creds|start|sync-loop)
            mode=$(cmd_detect) || exit 1
            [ "$mode" = shared ] && die "shared sandbox: '$sub' is never run here"
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
        *) printf 'usage: %s {detect|setup|install|creds|start|sync-loop|sync-now|status}\n' "$0" >&2; exit 2 ;;
    esac
fi
