# Beads migration: embedded 1.2.2 → server-mode 1.3.4 on DoltHub — handoff

Written 2026-11-28 at the end of the research session. Plain-language
summary: the beads task graph (prefix `kp`) moves off the git branch
`beads-dolt-data` and onto a private DoltHub database. The migration runs in
one cloud session with bd 1.3.4 and dolt 2.7.7 installed under `/tmp` (never
on `PATH`), against a **copy** of the data. Nothing in the repository's
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
  tell the agent; it only changes the URL in steps 3.10 and 3.12.
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
| Server-mode push/pull run as `CALL DOLT_PUSH/PULL` inside the server when the workspace has no local `.beads/dolt/kp/.dolt`, so they use the **server process's** dolt credentials (`DOLT_ROOT_PATH`) | v1.3.4 `storage/dolt/store.go:3900-3913, 4253-4350` |
| The workspace is treated as an external server when `metadata.json` has `dolt_server_port` (or `BEADS_DOLT_SERVER_MODE=1`) | v1.3.4 `doltserver/servermode.go` |
| bd's documented embedded→server route is `bd backup` + `bd init --server` + `bd backup restore` (v1.3.4 `docs/architecture/dolt.md:335-358`). This plan copies the Dolt directory instead, to keep Dolt history (owner chose option A). The documented route is the fallback | — |

Not verified, so watch for these: authenticated push to DoltHub; whether DoltHub's
"empty" database already has a commit (if a push is rejected as
non-fast-forward, stop and report — do not force-push without the owner);
`bd bootstrap` against a DoltHub URL end to end; dolt 2.7.7 behaviour under
bd beyond the step 3.6 check.

---

## Part 3 — Agent procedure (next session)

Rules for the whole procedure:
- Read `AGENTS.md` first. Never read `retrospective/`.
- **Never put bd 1.3.4 or dolt on `PATH`, and never run them inside the repository.** The 1.2.2 hooks
  still run every turn against the repo's `.beads/`, and bd finds its
  workspace by walking up from the current directory.
- Never print `DOLTHUB_CREDS_JWK`.
- Any unexpected result: stop and report to the owner. Do not improvise.

Shell setup used by every step (re-export in each Bash call):

```bash
export M=/tmp/migr
export DOLT=/tmp/dolt277/dolt-linux-amd64/bin/dolt
export BD=/tmp/bd134bin/node_modules/.bin/bd
export DOLT_ROOT_PATH=$M/doltroot          # dolt global config + creds
export BEADS_DIR=$M/ws/.beads              # bd 1.3.4 workspace (outside git)
export BEADS_DOLT_AUTO_START=0 BEADS_DOLT_SERVER_MODE=1 BD_NO_REMOTE_ADOPT=1
export URL="https://doltremoteapi.dolthub.com/$DOLTHUB_OWNER/k8s-platform"
```

**3.1 Baseline checks.**
- `git ls-remote origin refs/heads/beads-dolt-data` must equal `b08e137…`. If
  it differs, stop: someone wrote beads since the backup.
- `bd version` (on `PATH`) must be 1.2.2, and `bd list --all -n 0 --json` must return 175 records.

**3.2 Install the tools.**
- Download `https://github.com/dolthub/dolt/releases/download/v2.7.7/dolt-linux-amd64.tar.gz`
  to `/tmp/dolt277` and check it against the SHA-256 in Part 2. Unpack it there.
- Run `npm install --prefix /tmp/bd134bin --no-save @beads/bd@1.3.4`.
- Confirm `$DOLT version` and `$BD version`, and that `which -a bd` shows only the 1.2.2 binary.

**3.3 Dolt identity and key.**

```bash
mkdir -p $DOLT_ROOT_PATH
$DOLT config --global --add user.name "<owner name>"
$DOLT config --global --add user.email "<owner email>"
$DOLT config --global --add metrics.disabled true
printf '%s' "$DOLTHUB_CREDS_JWK" | $DOLT creds import --no-profile
$DOLT creds ls && $DOLT creds check
```

**3.4 Copy the data, then cut the GitHub remote first.**

```bash
mkdir -p $M/server-data && cp -a /home/user/k8s-platform/.beads/embeddeddolt/kp $M/server-data/kp
cd $M/server-data/kp && $DOLT remote remove origin && $DOLT remote -v   # must print nothing
tar -czf $M/kp-v53-precopy.tar.gz -C $M/server-data kp
```

Verified on a copy in the research session with dolt 2.7.7: after the remove,
- `dolt remote -v` prints nothing
- `SELECT * FROM dolt_remotes` returns no rows
- `.dolt/repo_state.json` has `"remotes": {}`
- `dolt branch -a` shows only `main`, because `remotes/origin/main` goes too
- `dolt status` is clean

Check all five before going on.

**3.5 Start the server.**

```bash
cd $M && nohup $DOLT sql-server --data-dir $M/server-data --host 127.0.0.1 --port 3307 > $M/server.log 2>&1 &
```

**3.6 dolt 2.7.7 reset check** (from v1.3.4 `docs/architecture/dolt.md:88-104`).
Run these against the running server, from `$M/server-data/kp`:
- `SELECT * FROM dolt_status` must return no rows.
- `SELECT 1` must succeed.
- `CALL DOLT_RESET('--hard')` must succeed. `Error 1105 … context canceled` means the database is affected: stop and report.

**3.7 The bd 1.3.4 workspace.**
- Create `$M/ws/.beads` with mode 700.
- Write `metadata.json`:

```json
{"database":"dolt","backend":"dolt","dolt_mode":"server",
 "dolt_server_host":"127.0.0.1","dolt_server_port":3307,"dolt_server_user":"root",
 "dolt_database":"kp","project_id":"17da1eb8-9148-4876-8211-c350c56aa14c"}
```

- Write a `config.yaml` with **no** `sync.remote`. Do not create `$M/ws/.beads/dolt/`.

**3.8 Migrate.** Run every command from `$M/ws`:

```bash
$BD migrate --inspect --json      # expect v53 -> v66
$BD migrate schema                # no remote, so this is the consent
$BD recompute-blocked
```

- Check that `schema_migrations` max is 66 and that `dolt_status` is clean, committing if needed.
- Keep `$M/server.log`.

**3.9 Compare #1** (migrated server vs the 1.2.2 repo DB vs R2 export).
- Pull every bead individually with both binaries:
  - 1.3.4: `$BD show --id=<id> --long --json --include-comments --include-dependents`, `$BD dep list <id> [--direction up] --json`, `$BD comments <id> --json`, `$BD label list <id> --json`.
  - 1.2.2: the same commands with the `bd` on `PATH`, run from the repo with the 1.3.4 variables removed (`env -u BEADS_DIR -u BEADS_DOLT_SERVER_MODE -u BEADS_DOLT_AUTO_START bd …`), or `BEADS_DIR` would send them to the new workspace.
- Compare field by field, and also against `beads-export-all-20261128T041141Z.jsonl` from R2.
- Expected differences only:
  - comment IDs: compare comments by author, text and `created_at` instead
  - fields new in 1.3.x, such as `is_blocked`
  - `bd show` text changes
- Counts must match: 175/362/85/372. `updated_at` must be unchanged, because 1.3.4 does not restamp.
- Anything else: stop.

**3.10 Push to DoltHub.**

```bash
$BD dolt remote add origin "$URL"     # or SQL: CALL DOLT_REMOTE('add','origin','<URL>')
$BD dolt push
```

If the push is rejected or authentication fails, stop and report.

**3.11 Archive the migrated copy.**
- Stop the server.
- Tar `$M/server-data/kp`. It holds the 738 events locally, and they will not
  come back from DoltHub.
- Ask the owner before uploading the tar to R2 bucket `k8s-platform-beads-2026-11-27`.

**3.12 Delete and re-clone from DoltHub.**
- Run `rm -rf $M/server-data/kp`, then start the server again on the empty data dir.
- Set `sync.remote: "<URL>"` in `$M/ws/.beads/config.yaml`.
- Run `$BD bootstrap` from `$M/ws`. It clones into `kp` via `CALL DOLT_CLONE`.
- Fallback: `$DOLT clone "$URL" kp` inside `$M/server-data` before starting the server.

**3.13 Compare #2.** Repeat 3.9 against the re-cloned database.
- `events` is expected to be empty (#7039). Everything else must match.
- Do not run `bd compact` or `bd flatten`.

**3.14 Report and stop.** Report the results, evidence and any discrepancies
to the owner. Then, **only with the owner's approval**, open one PR that:
- removes the beads hooks (`beads-prepush-guard.sh`, `beads-push.sh`, `beads-status.sh`, the beads block in `session-start.sh`) and their `.claude/settings.json` entries
- removes `scripts/beads-sync.sh` and `BD_VERSION`
- updates `AGENTS.md` and `.claude/skills/beads/`

The `beads-dolt-data` and `__dolt_remote_info__` branches stay as the frozen archive.

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
