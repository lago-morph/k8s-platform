# Beads on Dolt with a Git remote — condensed reference for future sessions

Purpose: everything a session needs to make beads store its data in this
repository's GitHub remote from the Claude Code web sandbox, without
re-reading the sources. Condensed 2026-09-08 from: DoltHub "Announcing Git
remote support in Dolt" (2026-02-13), DoltHub "Supporting Git remotes as
Dolt remotes" (2026-02-19 deep dive), the beads README and docs
(`docs/architecture/dolt.md`, `core-concepts/sync-concepts.md`,
`reference/protected-branches.md`, `getting-started/ide-setup.md`), the
Dolt CLI reference, plus probes run in this sandbox on 2026-09-08.

## 1. Mechanism (Dolt side)

- Since Dolt v1.81.10 a Git repository can be a Dolt remote. Accepted URL
  forms: `https://github.com/org/repo.git`, `git+https://…`,
  `git+ssh://git@github.com/org/repo.git`. Dolt rewrites them to the
  internal `git+<scheme>://` form.
- Hard dependency on the `git` binary on PATH: Dolt shells out to git
  plumbing. Whatever credentials make `git push` work make `dolt push`
  work. Known bug in v1.81.10: git must not prompt for user/password on
  stdin.
- All data lives on **one custom ref**, default `refs/dolt/data`,
  **configurable per remote with `--ref`** on `dolt remote add`, `dolt
  clone`, `dolt fetch`, `dolt backup`, `dolt read-tables`. The ref points
  at a commit whose tree holds the Dolt manifest plus immutable tablefiles
  as blobs; tablefiles over the per-object size limit are chunked into a
  sub-tree (`<key>/0001`, `<key>/0002`, …). Git never fetches this ref
  unless asked.
- Local side: a bare git repo inside the Dolt data directory (one per
  database), with a remote pointing at the URL. Reads start with
  `git fetch <ref>`; writes build a commit on top of the fetched head and
  push with `git push --force-with-lease=<ref>:<expected-oid>` — that
  lease is the compare-and-swap. A rejected push refetches and retries.
  The manifest (the only mutable file) additionally uses an
  application-level CAS on its object id.
- Consequences: every push is a **forced update** of that ref; the ref's
  history is a chain of "put <key>" commits; only the manifest changes,
  tablefiles are content-addressed and immutable.
- The Git repo must already exist and contain at least one branch. Using
  an existing source repo is safe. Inspect with
  `git ls-remote origin refs/dolt/data`; destroy with
  `git push origin :refs/dolt/data`.
- GitHub Actions can read the data with the job token:
  `dolt clone https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git db`
  (add `--ref <ref>` when not using the default).

## 2. Beads specifics

- Storage modes: **embedded** (`bd init`; Dolt in-process, data in
  `.beads/embeddeddolt/`, single writer, no `dolt` binary needed) or
  **server** (`bd init --server`; external `dolt sql-server`, data in
  `.beads/dolt/`). Embedded is the fit for one sandbox at a time.
- If the `dolt` CLI is ever installed (server mode, `dolt sql`), beads
  pins **Dolt 2.2.0**; never install `releases/latest` (2.3.x has a
  `DOLT_RESET('--hard')` bug that breaks `bd flatten`, `bd admin
  compact` and the pull merge-settle path; the `latest` URL can also move
  backwards).
- Sync commands: `bd dolt push`, `bd dolt pull`. `bd init` auto-detects
  `git remote get-url origin` and persists it as `sync.remote` in
  `.beads/config.yaml`; the first push publishes `refs/dolt/data`.
  Fresh clone: `bd bootstrap` probes origin for the ref, clones the Dolt
  database and wires the remote. `.beads/issues.jsonl` is an **export**
  only (viewers, interchange), refreshed by the pre-commit hook when
  `export.auto=true`; it is not the sync channel and must not be
  imported as one.
- `bd dolt remote add origin <url>` registers the remote through the
  Dolt store API and persists `sync.remote`; for git-protocol remotes bd
  "materializes a matching local CLI remote" at push/pull time.
- Files to commit: `.beads/.gitignore`, `.beads/metadata.json`,
  `.beads/config.yaml` (plus any root `.gitignore` change). The data
  directory stays gitignored.
- Claude Code integration: `bd setup claude` writes a **SessionStart**
  hook running `bd prime --hook-json` (SessionStart also fires on resume,
  clear and after compaction) and a minimal managed section in
  `CLAUDE.md`. `bd hooks install` installs git hooks (pre-commit export;
  post-merge/post-checkout only do a legacy JSONL import when no Dolt
  remote is configured). `bd setup claude --check` verifies.
- Agent authority: `agent.profile` = `conservative` | `minimal` |
  `team-maintainer` (env `BD_AGENT_PROFILE` overrides). Only
  `team-maintainer` lets agents run `bd dolt push` and `git push` as
  routine work; explicit "do not push" instructions still win.
- Schema-version guard: an older `bd` refuses to open a database
  migrated by a newer one. Pin the `bd` version (one value, installed
  identically by the session hook and CI) and upgrade deliberately.
- Install options: install script
  (`curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash`,
  verifies release checksums), `brew install beads`, `npm i -g @beads/bd`.
  Upstream repo moved to `gastownhall/beads`; Go module path is still
  `github.com/steveyegge/beads`.
- Concurrency model: embedded mode is single-writer per clone; separate
  clones sync through the remote. The git-level CAS serialises blob
  writes, it does not merge diverged Dolt history: pull before work, push
  at hand-off, and on a rejected push pull (merge) then push again.

## 3. Sandbox constraints (verified in this sandbox, 2026-09-08)

Git traffic leaves through the agent proxy, which injects the push
credential. Probes against `origin`:

| Operation | Result |
|---|---|
| Push a new branch | OK |
| `--force-with-lease` update of an existing branch | OK |
| Push to `refs/dolt/<name>` (any non-branch ref) | **HTTP 403** |
| Delete a branch | **HTTP 403** |

Implications:

- The default `refs/dolt/data` is unusable from the sandbox. The Dolt
  data ref must be a **branch**, e.g. `refs/heads/beads-dolt-data`, set
  with `--ref`. Forced updates to branches are allowed, which is what
  Dolt's CAS push needs.
- That branch will show in GitHub's branch list and contains only Dolt
  blobs: never open PRs from it, never "clean up" stale branches
  blindly, and any branch-protection rule on it must allow force pushes.
- The sandbox cannot delete branches, so a wrongly created branch needs
  the GitHub UI or an API call to remove.
- Every session is a fresh clone: a SessionStart hook must install the
  pinned `bd`, then `bd bootstrap` (first time) or `bd dolt pull`, then
  `bd prime`. The sandbox is ephemeral, so `bd dolt push` must be driven
  by a hook at session end / before compaction, not by instructions.

## 4. Open questions to settle by experiment (step 2), not by assumption

1. Does `bd` honour a non-default data ref end to end? Candidates: a
   `--ref` pass-through on `bd dolt remote add`, a `sync.remote` URL
   form, or setting the ref on the underlying Dolt remote inside
   `.beads/embeddeddolt/` and confirming bd's remote re-materialization
   keeps it. Test the full loop: init → push → fresh clone → `bd
   bootstrap` → pull → push.
2. Which Claude Code hook events fire in the web sandbox for "session is
   ending" (Stop, SessionEnd, PreCompact) and whether a hook can run
   `bd dolt push` reliably there; plus a PreToolUse guard on `git push`
   that refuses to push code while beads has unsynced changes.
3. `tests/unit/test_root_file_allowlist.sh` must admit `.beads/`;
   `.beads/embeddeddolt/` must be gitignored; `versions.env` gets the
   `bd` pin.
4. The `bd prime` context (~1–2k tokens) versus the existing
   `AGENTS.md` budget: `bd setup claude` writes into `CLAUDE.md`, which
   this repo keeps as a pointer to `AGENTS.md`.
