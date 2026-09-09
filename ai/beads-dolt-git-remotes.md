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
- Every session is a fresh clone: the SessionStart hook installs the
  pinned `bd`, bootstraps or pulls, and prints status + `bd ready`. The
  sandbox is ephemeral and a reclaimed container never runs SessionEnd,
  so pushes are driven by the hooks that fire while the process lives:
  **Stop** (after every assistant turn; 0.15 s when nothing to push),
  **PreCompact**, and the **PreToolUse guard on `git push`** (beads first,
  code push blocked if that fails). SessionEnd is wired as a bonus only.
  The loss window is the current turn. A rejected push (another clone
  pushed first) is retried once after `bd dolt pull`.

## 4. Experiment results (2026-09-08, bd 1.2.2, this sandbox) — the mechanism in use

Everything below was tested in three throwaway clones and then applied
to this repository; `scripts/beads-sync.sh` encodes it. Prefix `kp`,
database `kp`, data on `refs/heads/beads-dolt-data`.

- **Branch ref works, but not through `bd`.** `bd dolt remote add --ref`
  does not exist (`unknown flag`), and `sync.ref` / `dolt.ref` config keys
  are written but ignored. What works is the Dolt remote parameter
  `params.git_ref` in `.beads/embeddeddolt/kp/.dolt/repo_state.json`
  (`remotes.origin = {url: "git+https://github.com/lago-morph/k8s-platform.git",
  params: {git_ref: "refs/heads/beads-dolt-data"}}`). Dolt then pushes
  `--force-with-lease=refs/heads/beads-dolt-data:<oid>`. bd's remote
  re-materialization never overwrote the parameter across many cycles,
  but the file is gitignored, so **every clone must re-apply it before
  the first push** — the helper does this on every `push` and `bootstrap`.
  A push without it spends ~70 s retrying `refs/dolt/data` and ends in 403.
- **URL must end in `.git`** or Dolt does not treat it as a Git remote; the
  sandbox origin URL has no suffix, so the helper normalises it.
- **`bd bootstrap` cannot clone from a branch ref** (it hardcodes
  `refs/dolt/data`; error "remote at that url contains no Dolt data"), and
  `bd init` + `bd dolt pull` fails with "no common ancestor". The helper's
  `bootstrap` fetches the branch into a throwaway local bare repo where the
  data sits on `refs/dolt/data`, points `sync.remote` at `git+file://` for
  one `bd bootstrap --yes`, restores the config, and rewrites
  `repo_state.json` to the real remote. Round trips between clones verified.
  **Never run bare `bd init` in a clone**: its divergence guard only looks
  for `refs/dolt/data`, so it happily creates an unrelated database that
  can never merge.
- **Dolt creates a second branch, `__dolt_remote_info__`** (one small
  `DOLT_REMOTE.md`), force-pushed on every push. Both branches are Dolt's;
  never open PRs from them, never delete or protect them, and exclude them
  from any branch automation. Branch protection that forbids force pushes
  would break sync.
- **Conflicts.** Different beads edited in two clones merge cleanly on
  `bd dolt pull`. The *same* bead edited in two clones (even different
  fields) is unrecoverable in bd 1.2.2 except by discarding one side
  (`rm -rf .beads/embeddeddolt && scripts/beads-sync.sh bootstrap`, redo
  the edit) or `bd dolt push --force` (destroys the other side). Rule:
  pull at session start (the hook does), push at hand-off (the hooks do),
  and do not run two sessions against the same bead.
- **Cheapest probes.** Unpushed local commits: `bd diff origin/main main`
  prints "No changes between origin/main and main" when clean (0.15 s,
  offline). Remote ahead: `bd dolt pull` is a safe no-op (~1.5 s).
  `bd dolt status` and `bd vc status` answer neither question.
- **Timings.** bootstrap on a fresh clone ~2.4 s; pull/push with nothing
  to do ~1.5 s; push with changes 11–14 s; `bd ready --json` 0.15 s;
  `bd prime` 0.15 s but 5.5 KB of generic protocol text — the hooks print
  `beads-sync.sh status` + `bd ready` instead.
- **`bd setup claude` rewrites `.claude/settings.json` wholesale** (reorders
  keys, re-escapes strings) and appends a managed block to `CLAUDE.md`;
  the hooks are hand-written instead. `bd init --skip-agents --skip-hooks`
  still auto-commits and appends to the root `.gitignore`; the seed commit
  folded that in.
- **`bd create --deps "blocks:<id>"` means the NEW issue blocks `<id>`**,
  not the reverse; to make X depend on Y use `bd dep add X Y`. The seed
  script got this backwards once and was corrected with `bd dep remove`.
- Tracked files: `.beads/.gitignore`, `.beads/README.md`,
  `.beads/config.yaml` (one live key, `sync.remote`), `.beads/metadata.json`;
  root `.gitignore` gained Dolt patterns. `.beads/embeddeddolt/` and
  `.beads/interactions.jsonl` stay untracked.
- Not yet tested: GitHub Actions reading the data (needs the `dolt` CLI with
  `clone --ref`), `bd hooks install` (deliberately not used), behaviour if
  `main` is ever force-pushed.
