# Beads migration: embedded 1.2.2 → server-mode 1.3.4 on DoltHub — handoff

Written 2026-11-28 at the end of the research session. Plain-language
summary: the beads task graph (prefix `kp`) moves off the git branch
`beads-dolt-data` and onto a private DoltHub database. The migration runs in
one cloud session with bd 1.3.4 and dolt 2.7.7 installed under `/tmp` (never
on `PATH`), using bd's documented embedded→server route (backup with 1.2.2,
`bd init --server` and restore with 1.3.4). Nothing in the repository's
`.beads/` is touched until the owner approves the clean-up PR at the very end.

Rollback at every step: the R2 backups (Part 4) and the untouched
`beads-dolt-data` branch at `b08e13723303b098c6ebc7334055e5f08ad09461`.

---

## Part 1 — Owner: before starting the next session

### 1.1 Make a DoltHub key pair (on your own machine, never in a cloud session)

```bash
dolt creds new
```

- Prints `pub key: <public key>` and writes the private key to
  `~/.dolt/creds/<key-id>.jwk` (or `$DOLT_ROOT_PATH/.dolt/creds/` if that is set).
- **It never overwrites an existing key.** Each run generates a fresh random
  Ed25519 key pair, and the file name is that new key's own ID
  (dolt v2.7.7 `creds/creds.go:83-92`, `creds/jwk.go:109-125`), so existing
  `.jwk` files are left alone.
- It becomes the **active** key only if no key is active yet
  (`credcmds/new.go:97-110`). On a machine that already has one, the new key
  is created but not selected: run `dolt creds use <public key>` if you want
  that machine to use it. `dolt login` with no argument also generates a new
  key the same way.

### 1.2 Register the public key on DoltHub

DoltHub → Settings → Credentials → paste the **public** key, give it a
description such as `k8s-platform cloud sandbox`, then add it. Check it from your
machine:

```bash
dolt creds check --creds <public key>
```

Use a key dedicated to cloud sessions so it can be revoked on its own. The
Dolt docs do not describe per-database scoping, so assume the key can write
to every database on your account.

### 1.3 Put the private key in the cloud environment's secrets

| Variable | Value | Secret? |
|---|---|---|
| `DOLTHUB_CREDS_JWK` | The **entire contents** of `~/.dolt/creds/<key-id>.jwk` — one line of JSON, `{"d":"…","x":"…","kty":"OKP","crv":"Ed25519"}` | Yes |
| `DOLTHUB_OWNER` | Your DoltHub user or organisation name | No (or tell the agent in chat) |

The DoltHub **API token is not needed**: pushes and pulls authenticate with
the key. Leave it out (one fewer secret) unless you want the agent to use
DoltHub's web API.

### 1.4 Create the DoltHub database

- Name: **`k8s-platform`** (lowercase, hyphen). If you choose a different name,
  tell the agent; it only changes `$URL` in Part 3.
- Visibility: **private**. Leave it **empty**: no README or initial data.
- URL used by the agent: `https://doltremoteapi.dolthub.com/$DOLTHUB_OWNER/k8s-platform`.

### 1.5 Network

The environment's network policy must allow `www.dolthub.com` and
`doltremoteapi.dolthub.com`. Both were reachable from the research session
(an anonymous clone of a public DoltHub database worked with dolt 2.7.7).

### 1.6 Start the session

Start it on the branch that contains this file, and point the agent at
`ai/beads-dolthub-migration-handoff.md`.

---

## Part 2 — Facts established in the research session

| Fact | Evidence |
|---|---|
| Source data: bd 1.2.2 embedded DB `kp`, schema v53, 53/53 migration rows carry `content_hash` | dolt 2.7.7 query on a copy |
| Counts: 175 issues, 362 dependencies, 85 comments, 372 labels, 738 events, 0 wisps | same |
| `project_id` = `17da1eb8-9148-4876-8211-c350c56aa14c` | `.beads/metadata.json` |
| The copied DB still carries remote `origin` = `git+https://github.com/lago-morph/k8s-platform.git` with `git_ref=refs/heads/beads-dolt-data` | `dolt remote -v` on the copy |
| The proxy **allows force-pushes to branches**, so a push through that inherited remote would overwrite the archive | `ai/beads-dolt-git-remotes.md` §3 |
| Dependency `created_at` values sit 5–6 h before their issue's `created_at`. This is stored data from 1.2.2's local-time `NOW()`, not an export bug. 1.3.4 writes UTC for new rows only | direct SQL on the copy; v1.2.2 vs v1.3.4 `issueops/dependencies.go` |
| `bd export` counts (`dependency_count`/`dependent_count`) include only `blocks` edges, in both versions | v1.3.4 source + export check |
| dolt v2.7.7 linux-amd64 tarball SHA-256: `087d3bca4f8cde61281bee451f6018bf52f567454f578a149339ef91f466bd92`. Dolt publishes no checksums and its `install.sh` does not verify; the hash is as downloaded on 2026-11-28 | `sha256sum` |
| bd 1.3.4 installs off-`PATH` with `npm install --prefix /tmp/bd134bin @beads/bd@1.3.4`; the global `bd` stays 1.2.2 | done in the research session |
| Beads 1.3.4 pins the dolt CLI at **2.2.0** and has not measured versions after 2.3.1. 2.3.x has a `DOLT_RESET('--hard')` defect. 2.7.7 is the owner's choice, so run the check in step 3.6 | v1.3.4 `docs/architecture/dolt.md:44-118` |
| Embedded engine #7037 (`is_blocked` wrong after migration 0059) is fixed in dolt server ≥ 2.4.0. `bd recompute-blocked` is still advised once | v1.3.4 CHANGELOG 42-45, 677-694 |
| Migration 0062 makes `events` clone-local: new events never push. Rows committed before the flip stay in the remote's **history**, but a fresh clone's `events` table is empty (#7039, unfixed in 1.3.4). **Never run `bd compact` or `bd flatten`** on a clone | v1.3.4 CHANGELOG 36-41, 1785-1795 |
| Migration 0061 rekeys every comment, event and snapshot ID | v1.3.4 CHANGELOG 1766-1783 |
| Server-mode consent: with **no** Dolt remote, `bd migrate schema` is the consent; with any remote it needs `--force` | v1.3.4 `schema/remote_migrate_gate.go:1100-1158` |
| Server-mode push/pull run as `CALL DOLT_PUSH/PULL` inside the server when the workspace has no local `.beads/dolt/<database>/.dolt`, so they use the **server process's** dolt credentials (`DOLT_ROOT_PATH`) | v1.3.4 `storage/dolt/store.go:3900-3913, 4253-4350` |
| The workspace is treated as an external server when `BEADS_DOLT_SERVER_MODE=1` is set (used here), or when `metadata.json` has the deprecated `dolt_server_port` | v1.3.4 `doltserver/servermode.go` |
| **Route: bd's documented embedded→server migration**: `bd backup` (1.2.2) → `bd init --server` (1.3.4) → `bd backup restore --force` (1.3.4). It preserves full Dolt commit history | v1.3.4 `docs/architecture/dolt.md:293-358` |
| "Make a backup" in 1.2.2 is two commands: `bd backup init <dir>` (sets the destination) then `bd backup sync` (writes it). Bare `bd backup` prints help and exits 0. `sync` first commits any pending changes (`bd: pre-backup commit`) | v1.2.2 `cmd/bd/backup_dolt.go:73-96, 136-161`; v1.3.4 `docs/getting-started/upgrading.md:167-174` |
| 1.3.4 `bd backup restore` accepts only a local directory (no URL), runs `CALL DOLT_BACKUP('restore','--force',<file url>,<dolt_database>)` on the server, then copies the restored `_project_id` into `metadata.json`. bd and the server must both read the backup at the same absolute path | v1.3.4 `versioncontrolops/backup.go:37-48, 107-124`; `cmd/bd/backup_restore.go:105-120` |
| The restore does **not** migrate. The v53 → v66 migration runs only with explicit consent afterwards: `bd migrate schema`, plus `--force` if the database has any Dolt remote | v1.3.4 `schema/remote_migrate_gate.go:857-872, 1100-1158` |
| Local database name is **`k8s-platform`**, the same as on DoltHub. The prefix stays `kp`; the two are independent. `dolt sql-server` names each database after its directory under `--data-dir`, so the clone directory must equal `dolt_database`. bd only turns hyphens into underscores when it *derives* the name from the prefix (`init.go:1165-1185`); explicit names may contain hyphens (`storage/dolt/history.go:19`, `^[a-zA-Z_][a-zA-Z0-9_\-]*$`) | v1.3.4 source |
| Tested in the research session: dolt 2.7.7 serves a database named `k8s-platform` (create, insert, commit). bd 1.3.4 `init --server --prefix kp --database k8s-platform` against a pre-existing `k8s-platform` database adopted it (no stray `kp` database, schema v66, `dolt_database: k8s-platform`). `bd create` and `bd list` then worked, and the workspace's `.beads/dolt/` stayed empty, so push and pull go through the server | probes in `/tmp` |
| Non-deprecated external-server setup, tested in `/tmp`. Run `bd init --server --prefix kp --database k8s-platform` with `BEADS_DOLT_SERVER_HOST/PORT/USER` and `BEADS_DOLT_SERVER_MODE=1` in the environment. init then writes no host, port or user into `metadata.json`. Then write the port to `.beads/dolt-server.port`. `bd create`/`list` ran with no deprecation warning and bd started no server. Port precedence: env, then port file, then dolt `config.yaml`, then bd `dolt.port`, then metadata.json (deprecated) | v1.3.4 `internal/doltserver/doltserver.go:790-850`, `servermode.go:44-75` |
| `bd init --server` needs `BEADS_DIR` set when run outside a git repo (otherwise it runs `git init`). It writes a new `project_id`, which the restore then replaces | v1.3.4 `cmd/bd/init.go:1128-1139, 160, 1682` |

Not verified, so watch for these:
- authenticated push to DoltHub
- whether a clone of the empty DoltHub database works. If it fails, let
  `bd init --server` create `k8s-platform` and add the DoltHub remote after the restore
- whether `origin` survives `bd backup restore --force`. Check
  `SELECT * FROM dolt_remotes` after the restore and re-add it if it is gone
- a push rejected as non-fast-forward: stop and report. Do not force-push
  without the owner
- dolt 2.7.7 behaviour under bd beyond the step 3.5 check

---

## Part 3 — Agent procedure (next session)

Rules for the whole procedure:
- Read `AGENTS.md` first. Never read `retrospective/`.
- **Never put bd 1.3.4 or dolt on `PATH`, and never run them inside the repository.** The 1.2.2 hooks still run every turn against the repo's `.beads/`. bd finds its workspace from `BEADS_DIR` or by walking up from the current directory, so run everything from `/tmp`.
- Never print `DOLTHUB_CREDS_JWK`.
- Any unexpected result: stop and report to the owner. Do not improvise.

Variables used below (re-export in each Bash call):

```bash
export M=/tmp/migr
export DOLT=/tmp/dolt277/dolt-linux-amd64/bin/dolt
export BD134=/tmp/bd134bin/node_modules/.bin/bd     # bd 1.3.4; plain `bd` on PATH is 1.2.2
export DOLT_ROOT_PATH=$M/doltroot                   # dolt global config + DoltHub key
export URL="https://doltremoteapi.dolthub.com/$DOLTHUB_OWNER/k8s-platform"
# bd 1.3.4 workspace and external server, without the deprecated metadata.json port:
export BEADS_DIR=$M/ws/.beads BEADS_DOLT_SERVER_MODE=1 BEADS_DOLT_AUTO_START=0
```

These variables are for bd 1.3.4 only. Strip all three from every bd 1.2.2 command, as `$OLD` in 3.1 and `env -u` in 3.5 do.

### 3.0 Prepare

0. **Shared-sandbox and running-process check, before anything else.**
   - If `~/.local/state/ai-sandbox` exists, this machine is a shared sandbox with its own beads server, and the migration must not run here.
   - If any `dolt` process is running (`pgrep -a -x dolt`), something is already being served. The same goes for a `bd` process still running after a 5-second re-check (`pgrep -a -x bd`); the repo's own 1.2.2 hooks run short-lived `bd` commands, which are expected.
   - In either case: do not install bd or dolt, do not start a server, do not sync. Report to the owner immediately and stop.
   - The cloud sandbox in the research session had no marker directory and no `bd` or `dolt` processes (checked 2026-11-28).
1. **Baseline.** `git ls-remote origin refs/heads/beads-dolt-data` must equal `b08e137…`; if not, stop. `bd version` must be 1.2.2, and `bd list --all -n 0 --json` must return 175 records.
2. **Tools.**
   - Download `https://github.com/dolthub/dolt/releases/download/v2.7.7/dolt-linux-amd64.tar.gz` to `/tmp/dolt277`, check it against the SHA-256 in Part 2, and unpack it there.
   - Run `npm install --prefix /tmp/bd134bin --no-save @beads/bd@1.3.4`.
   - `which -a bd` must show only the 1.2.2 binary.
3. **Dolt identity and DoltHub key.**
   ```bash
   mkdir -p $DOLT_ROOT_PATH
   $DOLT config --global --add user.name "<owner name>"
   $DOLT config --global --add user.email "<owner email>"
   $DOLT config --global --add metrics.disabled true
   printf '%s' "$DOLTHUB_CREDS_JWK" | $DOLT creds import --no-profile
   $DOLT creds ls && $DOLT creds check
   ```

### 3.1 Back up with bd 1.2.2

Run this on a copy of the workspace, so no 1.2.2 write can reach the repo's database (and from there, the hooks' push).

```bash
mkdir -p $M/old && cp -a /home/user/k8s-platform/.beads $M/old/.beads
cd $M/old/.beads/embeddeddolt/kp && $DOLT remote remove origin && $DOLT remote -v   # must print nothing
cd /tmp
OLD='env -u BEADS_DOLT_SERVER_MODE -u BEADS_DOLT_AUTO_START BEADS_DIR=/tmp/migr/old/.beads bd'   # bd 1.2.2, embedded
$OLD backup init $M/kp-backup
$OLD backup sync
$OLD backup status
```

Removing `origin` from the copy is a safety step. That remote is the GitHub branch `beads-dolt-data`, and the proxy allows force-pushes to it. On a copy in the research session, dolt 2.7.7's `remote remove` left:
- no remotes in `dolt_remotes`
- `"remotes": {}` in `repo_state.json`
- only `main` in `dolt branch -a`
- a clean `dolt status`

### 3.2 Start the 1.3.4 server, pointed at the synced DoltHub database

```bash
mkdir -p $M/server-data && cd $M/server-data && $DOLT clone "$URL" k8s-platform   # the empty DoltHub database, same name locally
cd $M && nohup $DOLT sql-server --data-dir $M/server-data --host 127.0.0.1 --port 3307 > $M/server.log 2>&1 &
```

Run the reset check from v1.3.4 `docs/architecture/dolt.md:88-104` against `k8s-platform`:
- `SELECT * FROM dolt_status` returns no rows.
- `SELECT 1` succeeds.
- `CALL DOLT_RESET('--hard')` succeeds. `Error 1105 … context canceled` means stop.

If the clone of the empty database fails, skip it, start the server on the empty data dir, and let step 3.3 create `k8s-platform`. Then add the remote in step 3.4.

### 3.3 `bd init --server` with bd 1.3.4

```bash
mkdir -p $M/ws && cd $M/ws
BEADS_DOLT_SERVER_HOST=127.0.0.1 BEADS_DOLT_SERVER_PORT=3307 BEADS_DOLT_SERVER_USER=root \
  $BD134 init --server --prefix kp --database k8s-platform --non-interactive --skip-hooks --skip-agents
echo 3307 > $M/ws/.beads/dolt-server.port
```

Confirm that `$M/ws/.beads/metadata.json` has `dolt_mode: server` and `dolt_database: k8s-platform`, and **no** `dolt_server_port`. That field is deprecated in v1.3.4 (`internal/doltserver/doltserver.go:838-848`). Passing the connection by environment instead of `--server-*` flags keeps init from writing it. The port then comes from `.beads/dolt-server.port`, and `BEADS_DOLT_SERVER_MODE=1` marks the server as externally managed, so bd never starts or stops one.

### 3.4 Restore and migrate with bd 1.3.4

```bash
cd $M/ws
$BD134 backup restore --force $M/kp-backup
$BD134 migrate schema --force        # --force because the database has the DoltHub remote; without a remote, drop it
$BD134 recompute-blocked
```

Then check:
- `metadata.json` `project_id` is `17da1eb8-9148-4876-8211-c350c56aa14c`.
- `schema_migrations` max is 66.
- `dolt_status` is clean.
- `SELECT * FROM dolt_remotes` shows `origin` = `$URL`. If it is missing, run `$BD134 dolt remote add origin "$URL"`.

### 3.5 Compare #1

This compares the migrated server against the 1.2.2 repo database and the R2 export.
- Pull every bead individually with both binaries:
  - 1.3.4, from `$M/ws`: `$BD134 show --id=<id> --long --json --include-comments --include-dependents`, `$BD134 dep list <id> [--direction up] --json`, `$BD134 comments <id> --json`, `$BD134 label list <id> --json`.
  - 1.2.2: the same commands as `env -u BEADS_DIR -u BEADS_DOLT_SERVER_MODE -u BEADS_DOLT_AUTO_START bd …`, from the repo.
- Compare field by field, and also against `beads-export-all-20261128T041141Z.jsonl` from R2.
- Expected differences only:
  - comment IDs (migration 0061): compare comments by author, text and `created_at`
  - fields new in 1.3.x, such as `is_blocked`
- Counts must match: 175 issues, 362 dependencies, 85 comments, 372 labels.
- `updated_at` must be unchanged.
- Anything else: stop.

### 3.6 Push to DoltHub

```bash
cd $M/ws && $BD134 dolt push
```

If the push is rejected or authentication fails, stop and report. Then stop the server and tar `$M/server-data/k8s-platform` as an archive: it holds the 738 events locally, and those no longer push. Ask the owner before uploading that tar to R2.

### 3.7 Delete, re-sync from DoltHub, compare #2

1. Stop the server.
2. `rm -rf $M/server-data/k8s-platform`.
3. `cd $M/server-data && $DOLT clone "$URL" k8s-platform`.
4. Start the server again.
5. Repeat 3.5 against it.
   - Expected: `events` may be empty.
   - Everything else must match.
   - Do not run `bd compact` or `bd flatten`.

### 3.8 Report and stop

Report the results to the owner. **Only with the owner's approval**, open the clean-up PR described in Part 5. Leave the `$M/ws` workspace and the running server in place until it is merged, so the metadata it needs can be copied from them.

---

## Part 4 — Backups (R2 bucket `k8s-platform-beads-2026-11-27`)

| Object | SHA-256 / note |
|---|---|
| `beads-dir-20261128T041141Z.tar.gz` | full `.beads/` incl. the Dolt DB; hash in `SHA256SUMS-20261128T041141Z.txt` |
| `beads-dolt-data-20261128T041141Z.bundle` | git bundle of `beads-dolt-data` at `b08e137`; hash in the same file |
| `beads-export-all-20261128T041141Z.jsonl` | `bd export --all`, 175 records, `2e7f0322cf91a8a80fbaffff836b107b6df0e3a2c3914d95719ab4fbfe7af34c` |

The export was verified bead by bead against `bd show`, `bd comments`,
`bd label list` and `bd dep list` in the research session: all fields,
labels, 85 comments and 362 edges matched.

---

## Part 5 — Clean-up PR: strip the embedded/git-branch setup, start server mode at session start

None of this was tested in the research session. It is the design for one PR, opened only after Part 3 passes and the owner approves. It follows `AGENTS.md`: tests ship with the code, one logical change per commit.

### 5.1 Remove the old behaviour

| What | Where | Action |
|---|---|---|
| Per-turn push (Stop, PreCompact, SessionEnd) | `.claude/hooks/beads-push.sh` and its three entries in `.claude/settings.json` | Delete the file and the entries |
| Push-before-`git push` guard | `.claude/hooks/beads-prepush-guard.sh` and its `PreToolUse` `Bash` entry | Delete. Keep the `mcp__.*__execute` chainsaw-audit entry |
| Per-prompt status via the old script | `.claude/hooks/beads-status.sh` | Rewrite to call the new script (5.2) |
| bd 1.2.2 install + git-branch bootstrap at start | beads block in `.claude/hooks/session-start.sh` (lines 44-60) | Replace with 5.2 |
| The git-ref sync helper | `scripts/beads-sync.sh` | Delete |
| Its regression test | `tests/unit/test_beads_sync_shallow_bootstrap.sh` and `tests/unit/run.sh:197` | Delete both |
| Pin | `versions.env:42-50` (`BD_VERSION="1.2.2"` + comment) | Set `BD_VERSION="1.3.4"`. Add `DOLT_VERSION="2.7.7"` and `DOLT_SHA256="087d3bca4f8cde61281bee451f6018bf52f567454f578a149339ef91f466bd92"`. Rewrite the comment |
| Workspace identity | `.beads/metadata.json` | Replace with the migrated workspace's file: `{"database":"dolt","backend":"dolt","dolt_mode":"server","dolt_database":"k8s-platform","project_id":"17da1eb8-9148-4876-8211-c350c56aa14c"}`. No host, port or user |
| Remote | `.beads/config.yaml` `sync.remote:` | Set it to `"https://doltremoteapi.dolthub.com/<DOLTHUB_OWNER>/k8s-platform"`. Nothing may point at GitHub any more |
| bd-generated readme | `.beads/README.md` | Regenerate or rewrite for server mode |
| Mechanism doc | `ai/beads-dolt-git-remotes.md` | Move to `docs/archive/` with a one-line "superseded by server mode on DoltHub, date" header. Write a short `ai/beads-dolthub.md` describing 5.2 |
| References | `AGENTS.md:30-32`, `.claude/skills/beads/SKILL.md` (hooks section, "no beads database found" drill, shallow-clone note), `ai/environment.md:52,78` (add the DoltHub hosts, drop the "must live on a branch" line), `ai/roadmap.md:193-195`, `docs/open-issues.md:4` | Update to the new mechanism. `AGENTS.md` stays ≤150 lines. `ai/LESSONS.md` L42 is history: leave it |
| Archive branches | `beads-dolt-data`, `__dolt_remote_info__` on GitHub | Leave as the frozen archive. Optional owner action: lock them in the GitHub UI so nothing can write to them |

### 5.2 New behaviour: bd 1.3.4 in server mode, synced with DoltHub every minute

**`.claude/settings.json` `env` block.** Values apply to every session and its subprocesses (Claude Code docs, env-vars page). No `~` or `$HOME` expansion.

```json
"env": { "BEADS_DOLT_SERVER_MODE": "1", "BEADS_DOLT_AUTO_START": "0", "BD_NO_REMOTE_ADOPT": "1" }
```

- `BEADS_DOLT_SERVER_MODE=1` marks the server as externally managed: bd never starts or stops one (v1.3.4 `servermode.go`).
- `BEADS_DOLT_AUTO_START=0` is belt and braces.
- `BD_NO_REMOTE_ADOPT=1` is required. `bd sync` and `bd dolt push` otherwise adopt the **git origin (GitHub)** as the Dolt remote when none is configured (`bd sync --help`).

**New `scripts/beads-server.sh`.** Subcommands, each idempotent:

0. **`detect`**. Runs first, before every other subcommand. It decides whether this machine is a **shared sandbox**, whose beads server is managed outside this repository and must never be duplicated.

   **Owner rule: never start a bd or dolt server when one is already running on the machine.**

   - **Foreign processes:** a `dolt` process (`pgrep -x dolt`), or a `bd` process that is still there on a re-check 5 s later (`pgrep -x bd`). Transient `bd` commands are expected. Processes whose PIDs are in this script's own PID files (server and sync loop) are **not** foreign; they are this script's own processes from an earlier run, since SessionStart reruns on resume, clear and compact.
   - Marker: the directory `~/.local/state/ai-sandbox` exists. Its sync log is `~/.local/state/ai-sandbox/beads-sync.log`, and its state file is `~/.local/state/ai-sandbox/beads-sync.state`.
   - If the marker is **absent** and there are **no foreign processes**, this is an ordinary cloud sandbox: run `install`, `creds`, `start` and `sync-loop` below.
   - If the marker is **absent** but **foreign `bd` or `dolt` processes are running**, something unknown is serving on this machine, which is bad:
     - Set up nothing: no install, no server, no sync.
     - Tell the user immediately, listing the processes (`pgrep -a`).
     - Exit non-zero.
   - If the marker is **present**:
     - Running `bd` or `dolt` processes are expected here, because the shared server is one of them.
     - **Healthy:** a server answers at **127.0.1.1:3307**, user `root`, no password (for example `dolt --host 127.0.1.1 --port 3307 --no-tls -u root -p "" sql -q "SELECT 1"`), **and** `beads-sync.state` contains no record matching `beads-sync-HALTED`. Use that server:
       - Point bd at it with `BEADS_DOLT_SERVER_HOST=127.0.1.1` and `.beads/dolt-server.port` = `3307`.
       - Run **none** of `install`, `creds`, `start` or `sync-loop`. The shared sandbox does its own syncing, logged in `beads-sync.log`.
       - Use the `bd` already on that machine. If it is missing, do not install one: report it.
     - **Any other combination** (no server answering, a `beads-sync-HALTED` record, or both), the shared configuration is broken:
       - Install nothing, start nothing, sync nothing.
       - Print a loud message naming which check failed and pointing at `beads-sync.log`.
       - Exit non-zero, so the session-start hook and the status line tell the user something is wrong. Do not try to repair it.
   - The host is `127.0.1.1`, not `127.0.0.1`. This is intentional (owner, 2026-11-28).

   Decision table:

   | `~/.local/state/ai-sandbox` | Foreign `bd`/`dolt` processes | Server at 127.0.1.1:3307 | `beads-sync-HALTED` in `beads-sync.state` | Action |
   |---|---|---|---|---|
   | absent | none | — | — | Normal path: install, creds, start, sync-loop |
   | absent | running | — | — | Stop. Set up nothing, tell the user immediately |
   | present | (expected) | answers | absent | Use the shared server. Install, start and sync nothing |
   | present | (expected) | answers | present | Stop. Set up nothing, report broken shared config |
   | present | (expected) | no answer | absent | Stop. Set up nothing, report broken shared config |
   | present | (expected) | no answer | present | Stop. Set up nothing, report broken shared config |
1. **`install`**:
   - `npm install -g @beads/bd@$BD_VERSION` unless `bd version` already matches.
   - Download dolt `$DOLT_VERSION` from `https://github.com/dolthub/dolt/releases/download/v$DOLT_VERSION/dolt-linux-amd64.tar.gz`, refuse it unless `sha256sum` equals `$DOLT_SHA256`, and install `bin/dolt` to `/usr/local/bin/dolt`.
   - Both are on `PATH` now: there is no 1.2.2 left to protect.
2. **`creds`**:
   - If `DOLTHUB_CREDS_JWK` is unset, fail loudly ("no DoltHub key: beads unavailable this session").
   - Otherwise set the dolt `user.name`, `user.email` and `metrics.disabled` globals, then run `printf '%s' "$DOLTHUB_CREDS_JWK" | dolt creds import --no-profile` unless `dolt creds ls` already lists it.
   - Never echo the variable.
3. **`start`**:
   - Data dir `/home/user/.beads-dolt` (absolute, outside the repo).
   - If `k8s-platform/` is missing, run `dolt clone "<sync.remote URL>" k8s-platform` there. That is "sync from DoltHub" on a fresh container; an existing data dir is brought up to date by the first `bd sync`.
   - If no live server answers on 127.0.0.1:3307 (PID file plus a `SELECT 1` probe), start `nohup dolt sql-server --data-dir /home/user/.beads-dolt --host 127.0.0.1 --port 3307 > /home/user/.beads-dolt/server.log 2>&1 &` and wait until `SELECT 1` succeeds.
   - Write `3307` to `.beads/dolt-server.port`. It is gitignored, and it is the non-deprecated port source.
4. **`sync-loop`**:
   - If its PID file names a live process, exit. SessionStart runs again on `resume`, `clear` and `compact`, so this check prevents a second loop.
   - Otherwise start `nohup` a loop that runs `bd sync` from the repo root every 60 s and writes the exit code and timestamp to `.beads/sync-loop.status`. Add that name to `.beads/.gitignore`.
   - Exit codes, from `bd sync --help`:
     - 0: synced
     - 1: error
     - 2: merge conflict, nothing pushed
     - 3: transient, retry next tick
     - 4: stuck working set
   - On 2 or 4 the loop keeps running, but status must show it loudly. Never auto-resolve.
5. **`status`**: one line, `beads: ready=N in_progress=N last-sync=<code> <age>`, from `bd status --json` and the status file. Flag a last sync older than 3 min, or code 1, 2 or 4. On a shared sandbox, read the last result from `beads-sync.state` instead, and flag `beads-sync-HALTED`.

**Hooks after the PR:**
- `session-start.sh`: run `detect` first. If it reports a healthy shared sandbox, skip straight to `status` and `bd ready | head -20`. If it reports a broken one, print its message and stop the beads part of start-up. Otherwise, when `CLAUDE_CODE_REMOTE=true` run `install`, then always run `creds`, `start` and `sync-loop`, each with output redirected, then `status` and `bd ready | head -20`. A failure prints loudly but never fails session start.
- `UserPromptSubmit`: `beads-status.sh` runs `scripts/beads-server.sh status`. It is read-only and runs no sync.
- No Stop, PreCompact, SessionEnd or PreToolUse beads hooks. Loss window: up to one minute of beads writes if the container is reclaimed.

**Tests** (`tests/unit/`, registered in `run.sh`):
- `bash -n` and shellcheck on the new script.
- `BD_VERSION`, `DOLT_VERSION` and `DOLT_SHA256` read from `versions.env`, not hardcoded.
- The PID-file guard makes a second `sync-loop` a no-op (stub `bd`).
- `detect`, with stub `pgrep`: marker absent plus a foreign `dolt` or persistent `bd` leads to a non-zero exit with nothing installed or started. PIDs listed in the script's own PID files are ignored.
- `detect`, with a fake `HOME`: marker absent leads to the normal path. Marker plus a reachable stub server and no HALTED record leads to the shared path, and `install`, `start` and `sync-loop` are never called. Marker with no server, with a HALTED record, or with both leads to a non-zero exit with nothing installed or started.
- `creds` never prints the variable (stub `dolt`).
- No tracked file except archives still references `beads-sync.sh`, `beads-dolt-data` or `embeddeddolt`.

### 5.3 Open points for the owner

- **Keep a pre-`git push` `bd sync`?** It would close the one-minute window before code leaves the sandbox. It is not per-turn, but it is a hook, so it is the owner's call.
- **`dolt.auto-push`** (bd config) is not a timer: it pushes after write commands, at most once per interval (v1.3.4 `docs/reference/configuration.md:244-263`). The `bd sync` loop covers it, so leave auto-push off.
- **Background process survival.** Claude Code documents starting background processes from SessionStart with redirected output. It does not document their lifetime, so verify on the first session after the PR that the server and the loop are still alive several turns later.
- **Sessions without the secret** (or without DoltHub in the network policy) have no task graph. The hook must say so on every prompt rather than fail silently.
