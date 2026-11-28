# Onboarding a repository to beads in server mode on DoltHub

> **Superseded for new repositories (2026-11-28).** The onboarding skill this
> document seeded now exists: ai-sandbox's `beads-onboarding` skill and its
> **repo kit** (`ai-sandbox-beads-repo-kit`, ai-sandbox
> `modules/beads/README.md`). The kit replaced this repository's
> `scripts/beads-server.sh` and its three hooks with `.claude/beads/beads.sh`.
> File names below are the pre-kit ones. The pitfalls (section 8) and the
> identity rules (section 9) still apply.

Seed document for an onboarding skill. It says what a repository needs so
that every Claude Code session — an ephemeral cloud sandbox, a local
machine, or a **shared sandbox** whose beads server is managed elsewhere —
gets a working beads (`bd`) task graph, stored in a private DoltHub
database and synced automatically. The reference implementation is this
repository (`lago-morph/k8s-platform`); file names below point at it.

Status of the evidence: the migration steps and the "clone with
`bd bootstrap`" rule were exercised live on 2026-11-28 (bd 1.3.4, dolt
2.7.7). The session-start wiring (`scripts/beads-server.sh`) is covered by
offline unit tests with stubs; its first live run is the first session
after it merged. Treat anything marked *untested* accordingly.

## 1. The shape of the setup

| Piece | Lives in | Travels with the repo? |
|---|---|---|
| Issue data | DoltHub database; local copy in a data dir outside the checkout | No |
| Database name, project ID, `dolt_mode: server` | `.beads/metadata.json` | Yes |
| Remote URL | `.beads/config.yaml` `sync.remote` | Yes |
| Ignore list for bd's machine-local files | `.beads/.gitignore` | Yes |
| bd/dolt pins + dolt tarball SHA-256 | `versions.env` (or equivalent) | Yes |
| Behaviour env vars | `.claude/settings.json` `env` | Yes |
| Hooks | `.claude/settings.json` `hooks` + `.claude/hooks/*.sh` | Yes |
| Setup/sync script | `scripts/beads-server.sh` | Yes |
| DoltHub private key | cloud environment secret `DOLTHUB_CREDS_JWK` | **Never** |

Everything except the key and the data is committed, so a fresh clone of
the repository is enough to find, clone and sync the database.

## 2. One-time owner steps (outside any agent session)

1. **Key pair**, on the owner's own machine: `dolt creds new`. It never
   overwrites an existing key; it only becomes the active key if none is.
   Use a key dedicated to cloud sessions so it can be revoked alone.
2. **Register the public key** on DoltHub (Settings → Credentials). Check
   with `dolt creds check --creds <public key>`. Assume the key can write
   to every database on the account (no per-database scoping documented).
3. **Cloud environment secret** `DOLTHUB_CREDS_JWK` = the whole one-line
   JSON content of `~/.dolt/creds/<key-id>.jwk`. Optionally
   `DOLTHUB_OWNER` (not secret). No DoltHub API token is needed.
4. **Create the DoltHub database**: private, empty (no README). Its name
   becomes `dolt_database`; lowercase with hyphens is fine.
5. **Network policy** must allow `www.dolthub.com`,
   `doltremoteapi.dolthub.com`, `github.com` (dolt release tarball) and
   `registry.npmjs.org` (bd).

## 3. Decide the names

| Name | Example | Rule |
|---|---|---|
| Issue prefix | `kp` | Independent of the database name |
| Database (`dolt_database`) | `k8s-platform` | Must equal the DoltHub database name **and** the directory name under the server's `--data-dir` (`dolt sql-server` names databases after directories) |
| Remote | `https://doltremoteapi.dolthub.com/<owner>/<database>` | Goes in `sync.remote` |
| Data dir | `/home/user/.beads-dolt` | Absolute, outside the checkout |
| Port | `3307` | Written to `.beads/dolt-server.port` (gitignored) |

## 4. Files to commit

`.beads/metadata.json` — no host, port or user (the `dolt_server_port`
field is deprecated in 1.3.4):

```json
{"database":"dolt","backend":"dolt","dolt_mode":"server","dolt_database":"<database>","project_id":"<uuid>"}
```

Commit it byte-identical to what `bd bootstrap` writes: indented JSON with
**no trailing newline**. `bd bootstrap` (1.3.4) rewrites this file, and the
setup script runs it whenever the local database is missing, which in a
cloud sandbox is every session. If the committed copy ends in a newline,
every session starts with a one-byte diff that the uncommitted-changes stop
hook flags. The easiest way to get the exact bytes is to copy the file from
a bd run rather than hand-writing it (see 6.1).

`.beads/config.yaml` — at least:

```yaml
sync:
    remote: "https://doltremoteapi.dolthub.com/<owner>/<database>"
```

`.beads/.gitignore` — take the one `bd init --server` generates (1.3.4)
and add `sync-loop.status`. Root `.gitignore`: add `*.gate.lock*`.

`.claude/settings.json`:

```json
"env": { "BEADS_DOLT_SERVER_MODE": "1", "BEADS_DOLT_AUTO_START": "0", "BD_NO_REMOTE_ADOPT": "1" }
```

- `BEADS_DOLT_SERVER_MODE=1`: the server is externally managed; bd never
  starts or stops one.
- `BEADS_DOLT_AUTO_START=0`: belt and braces.
- `BD_NO_REMOTE_ADOPT=1`: **required**. Otherwise `bd sync`/`bd dolt push`
  adopt the git origin as the Dolt remote when none is configured.

Hooks:

| Event | Command | Purpose |
|---|---|---|
| `SessionStart` | `beads-server.sh setup`, then `status` and `bd ready \| head -20` | Bring beads up; never fail session start |
| `UserPromptSubmit` | `beads-server.sh status` | One read-only status line per prompt |
| `PreToolUse` (`Bash`, command contains `git push`) | `beads-server.sh sync-now` | Close the sync window before code leaves; block on exit 1/2/4 |

No `Stop`, `PreCompact` or `SessionEnd` beads hooks are needed. Run the
beads part of `SessionStart` **before** any "remote sessions only" early
exit, so local and shared machines get detection too.

## 5. The setup script's contract

Copy `scripts/beads-server.sh`; it reads the database name from
`metadata.json` and the pins from `versions.env`, so only the data-dir
default and the `versions.env` path are repository-specific.

### 5.1 Detection comes first

Owner rule: **never start a bd or dolt server when one is already running
on the machine.**

| `~/.local/state/ai-sandbox` | Foreign `bd`/`dolt` processes | Server at 127.0.1.1:3307 | `beads-sync-HALTED` in `beads-sync.state` | Action |
|---|---|---|---|---|
| absent | none | — | — | Normal path: install, creds, start, sync-loop |
| absent | running | — | — | Set up nothing; list the processes; exit non-zero |
| present | (expected) | answers | absent | Use the shared server; if it lacks the repo's database, `bd bootstrap` it there (fail loudly on a clone error); install, start and sync nothing |
| present | (expected) | answers | present | Set up nothing; report broken shared config |
| present | (expected) | no answer | either | Set up nothing; report broken shared config |

- "Foreign" excludes PIDs in the script's own PID files **and their
  descendants** (the server's `dolt send-metrics` child, the loop's
  `bd sync`) and zombies. A `bd` counts only if still alive on a re-check
  5 s later; hook-run `bd` commands are short-lived.
- The shared server is on **127.0.1.1**, not 127.0.0.1 (intentional). Point
  bd at it with `BEADS_DOLT_SERVER_HOST=127.0.1.1` — in the script's own
  environment, and for the agent's shell via `$CLAUDE_ENV_FILE` in the
  SessionStart hook.
- On a shared sandbox use the `bd` already there; if missing, report it.
- The repo's database is part of the repo: when the shared server answers
  but does not hold it (`bd status` fails), run `bd bootstrap --yes` against
  it. The clone runs inside the shared server with **its** DoltHub
  credentials; if it has none, show bd's error and exit non-zero. (The
  first version of this design assumed the shared server already held the
  database; it did not.)

### 5.2 Normal path

1. **install** (cloud only): `npm install -g @beads/bd@$BD_VERSION`; dolt
   from `https://github.com/dolthub/dolt/releases/download/v$DOLT_VERSION/dolt-linux-amd64.tar.gz`,
   refused unless `sha256sum` equals `$DOLT_SHA256` (Dolt publishes no
   checksums: record the hash yourself when pinning).
2. **creds**: fail loudly if `DOLTHUB_CREDS_JWK` is unset. Set dolt
   `user.name`, `user.email` (git's identity is fine) and
   `metrics.disabled`; skip the import if `dolt creds check` passes,
   otherwise `printf '%s' "$DOLTHUB_CREDS_JWK" | dolt creds import --no-profile`.
   Never echo the variable.
3. **start**: start `dolt sql-server --data-dir <data dir> --host 127.0.0.1 --port 3307`
   with `nohup … &` **launched directly** — `cd x && nohup … &` backgrounds a
   subshell, so `$!` is not the server and a later kill misses it (bit us
   in the migration). Wait for `SELECT 1`. Write `.beads/dolt-server.port`.
   If `<data dir>/<database>` is missing, run **`bd bootstrap --yes`** from
   the repo root.
4. **sync-loop**: if its PID file names a live process, exit. Otherwise
   `nohup` a loop running `bd sync` every 60 s, writing
   `<exit code> <epoch>` to `.beads/sync-loop.status`. Exit codes: 0 synced,
   1 error, 2 merge conflict (nothing pushed), 3 transient, 4 stuck working
   set. On 2/4 keep looping but make status loud; never auto-resolve.
5. **status**: `beads: ready=N in_progress=N last-sync=<code> <age>`; flag
   1/2/4, an age over 3 min, a bd that is not the pin, and
   "UNAVAILABLE — <reason>" when there is no server or key. On a shared
   sandbox read `beads-sync.state` instead and flag `beads-sync-HALTED`.

## 6. Seeding the DoltHub database

### 6.1 A brand-new graph (*untested as a whole*)

An empty DoltHub database **cannot be cloned** ("remote at that url
contains no Dolt data"), so the first copy is created locally and pushed.
From a scratch directory, with the dolt server already running on an
empty data dir:

```bash
export BEADS_DIR=$PWD/.beads BEADS_DOLT_SERVER_MODE=1 BEADS_DOLT_AUTO_START=0 BD_NO_REMOTE_ADOPT=1
BEADS_DOLT_SERVER_HOST=127.0.0.1 BEADS_DOLT_SERVER_PORT=3307 BEADS_DOLT_SERVER_USER=root \
  bd init --server --prefix <prefix> --database <database> --non-interactive --skip-hooks --skip-agents
bd dolt remote add origin "https://doltremoteapi.dolthub.com/<owner>/<database>"   # also sets sync.remote
bd dolt push
```

Each command was run live in the 2026-11-28 migration, with a restore
between init and remote-add. Copy the generated `metadata.json` (it holds
the new `project_id`), `config.yaml` and `.gitignore` into the
repository's `.beads/`.

- `BEADS_DIR` must be set outside a git repo, or `bd init` runs `git init`.
- Passing host/port/user by env (not `--server-*` flags) keeps init from
  writing the deprecated `dolt_server_port` into `metadata.json`.

### 6.2 Migrating an existing embedded (1.2.x) graph

Documented route, done live in `ai/beads-dolthub-migration-handoff.md`
Part 3: `bd backup init <dir>` + `bd backup sync` with the old bd (on a
**copy** of `.beads/`, with any git Dolt remote removed from the copy
first), then `bd init --server` and `bd backup restore --force <dir>` with
1.3.4, then `bd migrate schema` (add `--force` only if the database has a
Dolt remote), `bd recompute-blocked`, add the DoltHub remote, `bd dolt push`.
Verify by comparing every bead with both bd versions; expect only new
fields (`revision`) and rekeyed comment IDs to differ.

## 7. Verify a new repository

1. Fresh session: the SessionStart output shows `server started`,
   `cloning … via bd bootstrap` and a `beads: ready=…` line.
2. `bd list --all -n 0 --json | jq length` matches the DoltHub row count.
3. Kill nothing; a few turns later the status line's `last-sync` age stays
   under a minute (the background loop survives).
4. A `git push` runs `bd sync` first (visible in `<data dir>/sync-loop.log`).

## 8. Pitfalls (each cost time in the migration)

| Symptom | Cause | Fix |
|---|---|---|
| `table not found: leases` on every bd command | Database made with plain `dolt clone`; bd's machine-local tables are in `dolt_ignore` and never pushed | Delete it and use `bd bootstrap`; restarting the server does not help |
| `clone failed; remote … contains no Dolt data` | Empty DoltHub database | Create locally and push first (6.1) |
| Server "won't stop"; restart says `Port 3307 already in use` | PID saved from a backgrounded subshell | Launch dolt directly; kill by the real PID |
| `events` empty after clone | Events are machine-local since migration 0062 (#7039) | Expected. Never `bd compact`/`bd flatten` |
| Push/pull uses the wrong DoltHub identity | Push/pull run inside the server process | Import the key for the user that runs the server |
| Dolt remote silently becomes GitHub | bd adopts git origin when no remote is set | `BD_NO_REMOTE_ADOPT=1` |
| Old bd refuses the database | bd refuses databases migrated by a newer bd | One pin for every clone; status line checks it |
| Every session starts with `.beads/metadata.json` modified (only the final newline differs) | `bd bootstrap` rewrites the file without a trailing newline; the setup script bootstraps in every fresh sandbox | Commit the file without a trailing newline (section 4). Steady-state `bd status`/`ready`/`sync` leave it alone |
| `cannot close <id>: assignee is "owner", actor is "Claude"` | The assignee is the literal string `owner`, which no actor matches; in a sandbox every bd command, the owner's included, runs as `Claude` | Leave owner beads unassigned (section 9). For an already-assigned bead: `--actor <assignee>`, which keeps the audit trail honest, not `--force`, which records `Claude` |

## 9. Identity: actor, assignee and creator

bd 1.3.4, checked live on 2026-11-28.

- **Actor** (who is running the command): the first of `--actor`,
  `$BEADS_ACTOR`, `actor:` in `.beads/config.yaml`, git `user.name`,
  `$USER`. In a cloud sandbox git `user.name` is `Claude`, so the owner
  typing a command and the agent are the same actor. bd cannot tell
  them apart.
- **Assignee** (who may close or update the bead): empty on
  `bd create` unless `--assignee` is passed. `bd update --claim` sets it to
  the actor. bd refuses a close by any other actor unless that actor uses
  `--force`. An empty assignee lets any actor close or update the bead.
- **Creator** (`created_by`, plus bd's own `owner` field): the actor and
  git `user.email` at creation. They are audit-only and gate nothing. In a
  sandbox they are `Claude` and `noreply@anthropic.com`.

Rules this repo follows:

- Do not assign beads to a role string such as `owner`. No actor matches
  it, so it forces everyone, the owner included, onto `--force`. Owner-only
  beads stay unassigned and say "with the owner" or "owner decides" in the
  title. The guard is the repo's rules, not bd. (The seven
  `owner`-assigned beads were cleared on 2026-11-28.)
- Do not make the actor the owner's identity (`BEADS_ACTOR` or
  `actor:` in `config.yaml`) to get around the check. In a sandbox the
  agent would then act, and be recorded, as the owner.

