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
| The workspace is treated as an external server when `metadata.json` has `dolt_server_port` (or `BEADS_DOLT_SERVER_MODE=1`) | v1.3.4 `doltserver/servermode.go` |
| **Route: bd's documented embedded→server migration**: `bd backup` (1.2.2) → `bd init --server` (1.3.4) → `bd backup restore --force` (1.3.4). It preserves full Dolt commit history | v1.3.4 `docs/architecture/dolt.md:293-358` |
| "Make a backup" in 1.2.2 is two commands: `bd backup init <dir>` (sets the destination) then `bd backup sync` (writes it). Bare `bd backup` prints help and exits 0. `sync` first commits any pending changes (`bd: pre-backup commit`) | v1.2.2 `cmd/bd/backup_dolt.go:73-96, 136-161`; v1.3.4 `docs/getting-started/upgrading.md:167-174` |
| 1.3.4 `bd backup restore` accepts only a local directory (no URL), runs `CALL DOLT_BACKUP('restore','--force',<file url>,<dolt_database>)` on the server, then copies the restored `_project_id` into `metadata.json`. bd and the server must both read the backup at the same absolute path | v1.3.4 `versioncontrolops/backup.go:37-48, 107-124`; `cmd/bd/backup_restore.go:105-120` |
| The restore does **not** migrate. The v53 → v66 migration runs only with explicit consent afterwards: `bd migrate schema`, plus `--force` if the database has any Dolt remote | v1.3.4 `schema/remote_migrate_gate.go:857-872, 1100-1158` |
| Local database name is **`k8s-platform`**, the same as on DoltHub. The prefix stays `kp`; the two are independent. `dolt sql-server` names each database after its directory under `--data-dir`, so the clone directory must equal `dolt_database`. bd only turns hyphens into underscores when it *derives* the name from the prefix (`init.go:1165-1185`); explicit names may contain hyphens (`storage/dolt/history.go:19`, `^[a-zA-Z_][a-zA-Z0-9_\-]*$`) | v1.3.4 source |
| Tested in the research session: dolt 2.7.7 serves a database named `k8s-platform` (create, insert, commit). bd 1.3.4 `init --server --prefix kp --database k8s-platform` against a pre-existing `k8s-platform` database adopted it (no stray `kp` database, schema v66, `dolt_database: k8s-platform`). `bd create` and `bd list` then worked, and the workspace's `.beads/dolt/` stayed empty, so push and pull go through the server | probes in `/tmp` |
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
```

### 3.0 Prepare

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
BEADS_DIR=$M/old/.beads bd backup init $M/kp-backup
BEADS_DIR=$M/old/.beads bd backup sync
BEADS_DIR=$M/old/.beads bd backup status
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
BEADS_DIR=$M/ws/.beads BEADS_DOLT_AUTO_START=0 $BD134 init --server \
  --server-host 127.0.0.1 --server-port 3307 --server-user root \
  --prefix kp --database k8s-platform --non-interactive --skip-hooks --skip-agents
```

Confirm that `$M/ws/.beads/metadata.json` has `dolt_mode: server`, `dolt_database: k8s-platform` and `dolt_server_port: 3307`. bd 1.3.4 then warns on every command that `dolt_server_port` in `metadata.json` is deprecated in favour of `.beads/dolt-server.port`. In the research test it did not affect `bd create` or `bd list`.

### 3.4 Restore and migrate with bd 1.3.4

```bash
cd $M/ws
export BEADS_DIR=$M/ws/.beads BEADS_DOLT_AUTO_START=0
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
  - 1.2.2: the same commands with plain `bd`, from the repo, with `BEADS_DIR` unset.
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

Report the results to the owner. **Only with the owner's approval**, open one PR that:
- removes the beads hooks (`beads-prepush-guard.sh`, `beads-push.sh`, `beads-status.sh`, the beads block in `session-start.sh`) and their `.claude/settings.json` entries
- removes `scripts/beads-sync.sh` and `BD_VERSION`
- updates `AGENTS.md` and `.claude/skills/beads/`

`beads-dolt-data` and `__dolt_remote_info__` stay as the frozen archive.

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
