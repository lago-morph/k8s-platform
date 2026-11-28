#!/usr/bin/env bash
# scripts/beads-server.sh — bd 1.3.4 in server mode, synced with DoltHub
# (ai/beads-dolthub.md). Offline: every external command (pgrep, bd, dolt,
# npm, curl) is a stub on PATH; HOME, the repo root and the data dir are
# temp dirs. Covers the ai/beads-dolthub-migration-handoff.md 5.2 test list:
#   - bash -n + shellcheck
#   - pins come from versions.env, not the script
#   - the PID-file guard makes a second sync-loop a no-op
#   - detect: foreign dolt / persistent bd => non-zero, nothing set up;
#     our own PIDs are not foreign; marker => shared / broken decision table
#   - creds never prints DOLTHUB_CREDS_JWK
#   - start clones with `bd bootstrap`, never a plain `dolt clone` (a dolt
#     clone lacks bd's clone-local tables; found in the migration, 2026-11-28)
#   - no tracked file outside the archives references the old git-branch setup
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. "$(dirname "$0")/lib/test-helpers.sh"

REPO=$(pwd)
SCRIPT="$REPO/scripts/beads-server.sh"
WORK=$(mktemp -d)
LOOP_PIDS=()
cleanup() {
  local p
  for p in "${LOOP_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  pkill -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 1. syntax + shellcheck ------------------------------------------------
if bash -n "$SCRIPT"; then pass "bash -n beads-server.sh"; else fail "bash -n beads-server.sh"; fi
for f in "$SCRIPT" .claude/hooks/beads-status.sh .claude/hooks/beads-prepush-guard.sh .claude/hooks/session-start.sh; do
  if command -v shellcheck >/dev/null 2>&1; then
    if out=$(shellcheck -S warning "$f" 2>&1); then pass "shellcheck $f"; else fail "shellcheck $f" "$out"; fi
  elif [ "${CI:-}" = "true" ]; then
    fail "shellcheck $f" "shellcheck missing on CI"
  else
    echo "  NOTE: shellcheck not installed locally — skipped for $f (CI runs it)"
  fi
done

# ---- fixture ---------------------------------------------------------------
# new_env <name>: fresh fake HOME, repo root, data dir and stub bin.
new_env() {
  E="$WORK/$1"
  mkdir -p "$E/home" "$E/root/.beads" "$E/data" "$E/bin" "$E/log" "$E/inst"
  cat >"$E/root/versions.env" <<'EOF'
BD_VERSION="9.9.9"
DOLT_VERSION="8.8.8"
DOLT_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
EOF
  echo '{"dolt_mode":"server","dolt_database":"testdb"}' >"$E/root/.beads/metadata.json"
  # pgrep: answers from $E/pgrep.<name> (one PID per line); a file named
  # pgrep.<name>.once is answered only on the first call.
  cat >"$E/bin/pgrep" <<EOF
#!/bin/bash
n="\$2"
if [ -f "$E/pgrep.\$n.once" ]; then cat "$E/pgrep.\$n.once"; rm -f "$E/pgrep.\$n.once"; exit 0; fi
[ -f "$E/pgrep.\$n" ] && cat "$E/pgrep.\$n"
exit 0
EOF
  # bd: logs every call; version from $E/bd.version; sync exit code from $E/bd.sync.rc
  cat >"$E/bin/bd" <<EOF
#!/bin/bash
echo "bd \$*" >>"$E/log/bd"
case "\$1" in
  version) echo "bd version \$(cat "$E/bd.version" 2>/dev/null || echo 9.9.9) (stub)";;
  status) [ -f "$E/db.missing" ] && { echo "Error: database not found" >&2; exit 1; }
          echo '{"summary":{"ready_issues": 3, "in_progress_issues": 1}}';;
  sync) exit \$(cat "$E/bd.sync.rc" 2>/dev/null || echo 0);;
  bootstrap) [ -f "$E/bootstrap.fail" ] && { echo "clone failed: permission denied (no DoltHub credentials)" >&2; exit 1; }
             rm -f "$E/db.missing"; mkdir -p "$E/data/testdb";;
esac
exit 0
EOF
  # dolt: logs every call. `sql` (the SELECT 1 probe) succeeds when
  # $E/server.up exists; `sql-server` creates it and sleeps.
  cat >"$E/bin/dolt" <<EOF
#!/bin/bash
printf 'dolt' >>"$E/log/dolt"; for a in "\$@"; do printf ' %s' "\$a" >>"$E/log/dolt"; done; echo >>"$E/log/dolt"
for a in "\$@"; do
  case "\$a" in
    sql) [ -f "$E/server.up" ]; exit \$?;;
    sql-server) touch "$E/server.up"; exec sleep 300;;
    version) echo "dolt version \$(cat "$E/dolt.version" 2>/dev/null || echo 8.8.8)"; exit 0;;
    import) cat >"$E/log/import.stdin"; touch "$E/creds.ok"; exit 0;;
    check) [ -f "$E/creds.ok" ]; exit \$?;;
  esac
done
exit 0
EOF
  printf '#!/bin/bash\necho "npm $*" >>"%s/log/npm"\n' "$E" >"$E/bin/npm"
  printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && { echo garbage >"$2"; shift; }; shift; done\necho curl >>"%s/log/curl"\n' "$E" >"$E/bin/curl"
  chmod +x "$E/bin/"*
}
# run_s <args...>: the script under the current fixture. Output in $OUT, rc in $RC.
run_s() {
  OUT=$(env -u CLAUDE_CODE_REMOTE -u DOLTHUB_CREDS_JWK PATH="$E/bin:$PATH" HOME="$E/home" \
    BEADS_REPO_ROOT="$E/root" BEADS_DATA_DIR="$E/data" BEADS_DETECT_RECHECK_SECS=0 \
    BEADS_SYNC_INTERVAL=3600 BEADS_DOLT_INSTALL_DIR="$E/inst" ${EXTRA_ENV:-} \
    bash "$SCRIPT" "$@" 2>&1)
  RC=$?
}
nothing_set_up() { # <name>
  if [ ! -s "$E/log/npm" ] && ! grep -q 'sql-server' "$E/log/dolt" 2>/dev/null \
     && [ ! -f "$E/data/sync-loop.pid" ] && ! grep -q 'bootstrap' "$E/log/bd" 2>/dev/null; then
    pass "$1: nothing installed, started or synced"
  else
    fail "$1: something was set up" "npm=$(cat "$E/log/npm" 2>/dev/null) dolt=$(grep sql-server "$E/log/dolt" 2>/dev/null)"
  fi
}

# ---- 2. pins come from versions.env ----------------------------------------
if grep -nE '1\.3\.4|2\.7\.7|087d3bca' "$SCRIPT" >/dev/null; then
  fail "no hardcoded bd/dolt pins in beads-server.sh" "$(grep -nE '1\.3\.4|2\.7\.7|087d3bca' "$SCRIPT")"
else
  pass "no hardcoded bd/dolt pins in beads-server.sh"
fi
new_env pins
echo 0.0.1 >"$E/bd.version"
run_s install
if grep -q 'npm install -g @beads/bd@9.9.9' "$E/log/npm" 2>/dev/null; then
  pass "install takes BD_VERSION from versions.env"
else
  fail "install takes BD_VERSION from versions.env" "npm log: $(cat "$E/log/npm" 2>/dev/null)"
fi
new_env sha
echo 0.0.1 >"$E/dolt.version"
run_s install
if [ "$RC" -ne 0 ] && [ -f "$E/log/curl" ] && [ ! -e "$E/inst/dolt" ] && printf '%s' "$OUT" | grep -q 'SHA-256 mismatch'; then
  pass "install refuses a dolt tarball whose SHA-256 differs from DOLT_SHA256"
else
  fail "install refuses a dolt tarball whose SHA-256 differs from DOLT_SHA256" "rc=$RC out=$OUT"
fi

# ---- 3. sync-loop PID guard -------------------------------------------------
new_env loop
run_s sync-loop
first=$(cat "$E/data/sync-loop.pid" 2>/dev/null)
LOOP_PIDS+=("$first")
run_s sync-loop
second=$(cat "$E/data/sync-loop.pid" 2>/dev/null)
n=$(pgrep -f "$SCRIPT _loop" | while read -r p; do tr '\0' ' ' <"/proc/$p/environ" 2>/dev/null | grep -q "BEADS_DATA_DIR=$E/data" && echo "$p"; done | wc -l)
if [ -n "$first" ] && [ "$first" = "$second" ] && printf '%s' "$OUT" | grep -q 'already running' && [ "$n" -eq 1 ]; then
  pass "a second sync-loop is a no-op while the first is alive"
else
  fail "a second sync-loop is a no-op while the first is alive" "first=$first second=$second loops=$n out=$OUT"
fi
for _ in 1 2 3 4 5; do [ -f "$E/root/.beads/sync-loop.status" ] && break; sleep 1; done
if grep -qE '^0 [0-9]+$' "$E/root/.beads/sync-loop.status" 2>/dev/null; then
  pass "the loop records bd sync's exit code and a timestamp"
else
  fail "the loop records bd sync's exit code and a timestamp" "$(cat "$E/root/.beads/sync-loop.status" 2>/dev/null)"
fi
kill "$first" 2>/dev/null

# ---- 4. detect without the marker (stub pgrep) ------------------------------
new_env clean
run_s detect
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | tail -n1)" = normal ] && pass "detect: no marker, no processes => normal" || fail "detect: no marker, no processes => normal" "rc=$RC out=$OUT"

new_env fdolt
echo 999991 >"$E/pgrep.dolt"
EXTRA_ENV="DOLTHUB_CREDS_JWK=x" run_s setup
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q FOREIGN && pass "detect: foreign dolt => non-zero, reported" || fail "detect: foreign dolt => non-zero, reported" "rc=$RC out=$OUT"
nothing_set_up "foreign dolt"

new_env fbd
echo 999992 >"$E/pgrep.bd"
EXTRA_ENV="DOLTHUB_CREDS_JWK=x" run_s setup
[ "$RC" -ne 0 ] && pass "detect: bd still running on re-check => non-zero" || fail "detect: bd still running on re-check => non-zero" "rc=$RC out=$OUT"
nothing_set_up "persistent bd"

new_env tbd
echo 999993 >"$E/pgrep.bd.once"
run_s detect
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | tail -n1)" = normal ] && pass "detect: transient bd (gone on re-check) => normal" || fail "detect: transient bd (gone on re-check) => normal" "rc=$RC out=$OUT"

new_env own
echo 999994 >"$E/pgrep.dolt"; echo 999994 >"$E/data/server.pid"
echo 999995 >"$E/pgrep.bd"; echo 999995 >"$E/data/sync-loop.pid"
run_s detect
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | tail -n1)" = normal ] && pass "detect: PIDs in our own PID files are not foreign" || fail "detect: PIDs in our own PID files are not foreign" "rc=$RC out=$OUT"

# ---- 5. detect with the marker (fake HOME) -----------------------------------
shared_case() { # <name> <server up: 1|0> <halted: 1|0> <want: shared|broken>
  new_env "m-$1"
  mkdir -p "$E/home/.local/state/ai-sandbox"
  echo 999996 >"$E/pgrep.dolt"   # expected on a shared sandbox: never foreign here
  [ "$2" = 1 ] && touch "$E/server.up"
  [ "$3" = 1 ] && echo "2026-11-28T00:00:00Z beads-sync-HALTED rc=2" >"$E/home/.local/state/ai-sandbox/beads-sync.state"
  EXTRA_ENV="DOLTHUB_CREDS_JWK=x CLAUDE_CODE_REMOTE=true" run_s setup
  if [ "$4" = shared ]; then
    [ "$RC" -eq 0 ] && pass "marker, server=$2 halted=$3 => shared server used" || fail "marker, server=$2 halted=$3 => shared server used" "rc=$RC out=$OUT"
    grep -qx 3307 "$E/root/.beads/dolt-server.port" && pass "shared: port file points at 3307" || fail "shared: port file points at 3307"
    grep -q -- '--host 127.0.1.1' "$E/log/dolt" && pass "shared: probed 127.0.1.1, not 127.0.0.1" || fail "shared: probed 127.0.1.1" "$(cat "$E/log/dolt")"
  else
    [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q BROKEN && pass "marker, server=$2 halted=$3 => broken, non-zero" || fail "marker, server=$2 halted=$3 => broken, non-zero" "rc=$RC out=$OUT"
  fi
  nothing_set_up "marker, server=$2 halted=$3"
}
shared_case healthy 1 0 shared
shared_case halted 1 1 broken
shared_case down 0 0 broken
shared_case both 0 1 broken

# A healthy shared server that does not hold this repo's database yet: the
# database is part of this repo, so setup clones it there with bd bootstrap
# (owner, 2026-11-28). Still no install, no own server, no own sync loop.
shared_missing() { # <name> <bootstrap fails: 1|0>
  new_env "m-$1"
  mkdir -p "$E/home/.local/state/ai-sandbox"
  touch "$E/server.up" "$E/db.missing"
  [ "$2" = 1 ] && touch "$E/bootstrap.fail"
  EXTRA_ENV="CLAUDE_CODE_REMOTE=true" run_s setup
  if [ ! -s "$E/log/npm" ] && ! grep -q 'sql-server' "$E/log/dolt" 2>/dev/null && [ ! -f "$E/data/sync-loop.pid" ]; then
    pass "shared, database missing ($1): nothing installed, no own server or loop"
  else
    fail "shared, database missing ($1): nothing installed, no own server or loop"
  fi
}
shared_missing clone 0
if [ "$RC" -eq 0 ] && grep -q '^bd bootstrap --yes' "$E/log/bd" && [ ! -f "$E/db.missing" ]; then
  pass "shared, database missing: setup clones it with bd bootstrap"
else
  fail "shared, database missing: setup clones it with bd bootstrap" "rc=$RC out=$OUT bd=$(cat "$E/log/bd" 2>/dev/null)"
fi
shared_missing fails 1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'permission denied (no DoltHub credentials)'; then
  pass "shared, clone fails: setup exits non-zero and shows bd's error"
else
  fail "shared, clone fails: setup exits non-zero and shows bd's error" "rc=$RC out=$OUT"
fi
# The healthy case above (database present) must not bootstrap.
new_env m-present
mkdir -p "$E/home/.local/state/ai-sandbox"; touch "$E/server.up"
run_s setup
[ "$RC" -eq 0 ] && ! grep -q bootstrap "$E/log/bd" 2>/dev/null \
  && pass "shared, database present: no bootstrap" || fail "shared, database present: no bootstrap" "rc=$RC bd=$(cat "$E/log/bd" 2>/dev/null)"

# ---- 6. creds never prints the key ------------------------------------------
new_env creds
SECRET='{"d":"SECRETDVALUE42","x":"pub","kty":"OKP","crv":"Ed25519"}'
EXTRA_ENV="DOLTHUB_CREDS_JWK=$SECRET" run_s creds
all="$OUT$(cat "$E/log/dolt" 2>/dev/null)"
if [ "$RC" -eq 0 ] && ! printf '%s' "$all" | grep -q SECRETDVALUE42 && grep -q SECRETDVALUE42 "$E/log/import.stdin"; then
  pass "creds imports the key via stdin and never prints it"
else
  fail "creds imports the key via stdin and never prints it" "rc=$RC"
fi
new_env nocreds
run_s creds
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'beads unavailable this session' && pass "creds without the key fails loudly" || fail "creds without the key fails loudly" "rc=$RC out=$OUT"

# ---- 7. start bootstraps with bd, never dolt clone --------------------------
new_env start
run_s start
if [ "$RC" -eq 0 ] && grep -q '^bd bootstrap --yes' "$E/log/bd" && ! grep -q ' clone' "$E/log/dolt"; then
  pass "start clones via bd bootstrap, never dolt clone"
else
  fail "start clones via bd bootstrap, never dolt clone" "rc=$RC out=$OUT bd=$(cat "$E/log/bd" 2>/dev/null)"
fi
grep -qx 3307 "$E/root/.beads/dolt-server.port" && pass "start writes .beads/dolt-server.port" || fail "start writes .beads/dolt-server.port"
spid=$(cat "$E/data/server.pid" 2>/dev/null)
if [ -n "$spid" ] && tr '\0' ' ' <"/proc/$spid/cmdline" 2>/dev/null | grep -q 'sleep 300'; then
  pass "server.pid is the server process itself"
else
  fail "server.pid is the server process itself" "pid=$spid"
fi
: >"$E/log/bd"
run_s start
if [ "$RC" -eq 0 ] && ! grep -q bootstrap "$E/log/bd" && [ "$(grep -c 'sql-server' "$E/log/dolt")" -eq 1 ]; then
  pass "second start reuses the running server and the existing database"
else
  fail "second start reuses the running server and the existing database" "rc=$RC out=$OUT"
fi
kill "$spid" 2>/dev/null

# ---- 8. status line ----------------------------------------------------------
new_env status
echo "2 $(date +%s)" >"$E/root/.beads/sync-loop.status"
run_s status
printf '%s' "$OUT" | grep -q 'ready=3 in_progress=1 last-sync=2' && printf '%s' "$OUT" | grep -q 'MERGE CONFLICT' \
  && pass "status flags a merge conflict loudly" || fail "status flags a merge conflict loudly" "$OUT"
echo "0 $(( $(date +%s) - 600 ))" >"$E/root/.beads/sync-loop.status"
run_s status
printf '%s' "$OUT" | grep -q STALE && pass "status flags a sync older than 3 min" || fail "status flags a sync older than 3 min" "$OUT"
echo 1.2.2 >"$E/bd.version"; : >"$E/log/bd"
run_s status
printf '%s' "$OUT" | grep -q 'UNAVAILABLE' && ! grep -q '^bd status' "$E/log/bd" \
  && pass "status refuses to query with a bd that is not the pin" || fail "status refuses to query with a bd that is not the pin" "$OUT"

# ---- 9. no live references to the old git-branch setup ----------------------
refs=$(git ls-files -z | xargs -0 grep -lE 'beads-sync\.sh|beads-dolt-data|embeddeddolt' 2>/dev/null \
  | grep -vE '^(docs/archive/|retrospective/|ai/LESSONS\.md$|ai/beads-dolthub-migration-handoff\.md$|\.beads/\.gitignore$|tests/unit/test_beads_server\.sh$)' || true)
if [ -z "$refs" ]; then
  pass "no tracked file outside the archives references the old setup"
else
  fail "no tracked file outside the archives references the old setup" "$(echo "$refs" | tr '\n' ' ')"
fi

summary
