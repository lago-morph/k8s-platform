# ADR: Beads storage: DoltHub remote, bd in server mode against a per-session local dolt server, synced by a bd sync loop

- **ID**: ADR-1eb98d68ce
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-11-28
- **Source retrospective**: ../2026-11-28-300.md
- **PRs covered**: #300

## Context

Until 2026-11-28 the beads task graph (prefix `kp`, 175 issues) lived in bd
1.2.2's embedded Dolt engine, pushed as Dolt data onto the git branch
`beads-dolt-data` of this repository through a throwaway bare-mirror
bootstrap (`scripts/beads-sync.sh`) and pushed on every assistant turn by
Stop/PreCompact/SessionEnd hooks plus a pre-`git push` guard. That design
carried a shallow-clone bootstrap bug class (kp-du3), relied on the proxy
permitting force-pushes to a branch that held the only copy of the data,
and pinned the project to bd 1.2.2 while upstream moved to 1.3.x, whose
embedded engine had open defects (#7037) and whose documented
multi-machine story is server mode plus `bd sync`.

A shared sandbox (marker `~/.local/state/ai-sandbox`, server on
127.0.1.1:3307) also exists, with its own server and sync, which this
repository must never duplicate (owner rule: never start a bd or dolt
server when one is already running on the machine).

## Decision

Store the beads graph in a private DoltHub database and run bd in server mode against a dolt sql-server started per session, cloned with bd bootstrap and synced by bd sync every 60 s plus once before every git push.

- `.beads/metadata.json` (`dolt_mode: server`, `dolt_database:
  k8s-platform`, no host/port/user) and `.beads/config.yaml`
  (`sync.remote` = the DoltHub URL) are committed, so the location travels
  with the repo. The DoltHub key is the environment secret
  `DOLTHUB_CREDS_JWK`.
- `scripts/beads-server.sh setup` runs at SessionStart: detect (shared
  sandbox → use it and set up nothing; foreign bd/dolt or broken shared
  config → set up nothing, exit non-zero), install (cloud only; dolt
  tarball checksum-verified), creds, start (`bd bootstrap` when the
  database directory is missing — never `dolt clone`), sync-loop.
- The pre-`git push` hook runs one `bd sync` and blocks the push on exit
  1, 2 or 4; it allows the push on 3 (transient) or when beads is
  unavailable this session.
- `.claude/settings.json` sets `BEADS_DOLT_SERVER_MODE=1`,
  `BEADS_DOLT_AUTO_START=0`, `BD_NO_REMOTE_ADOPT=1`.

## Alternatives considered

- **Keep the embedded engine on a git branch (status quo).** Rejected:
  bd 1.2.2 pin, the shallow-clone bootstrap class, a force-pushable branch
  as the only copy, and per-turn push hooks.
- **Embedded 1.3.4 with a DoltHub remote.** Not chosen: the embedded
  engine carried the #7037 `is_blocked` defect (fixed only in dolt
  server ≥ 2.4.0), and server mode is what the shared sandbox already
  runs, so one model covers both machines.
- **`dolt.auto-push` instead of a loop.** Rejected: it pushes after write
  commands at most once per interval and never pulls; `bd sync` pulls,
  detects conflicts positively, repairs `is_blocked` and pushes.
- **Per-turn Stop-hook sync.** Rejected by the owner: hook load on every
  turn; the one-minute loop plus the pre-push sync bound the loss window.
- **Clone fresh containers with `dolt clone`.** Rejected after it failed
  live: bd's machine-local tables are in `dolt_ignore`, so a dolt clone is
  unreadable by bd (`table not found: leases`). `bd bootstrap` creates
  them.

## Consequences

- Easier: a fresh container needs only the secret and network access to
  DoltHub; no git-ref plumbing; one bd version (1.3.4) everywhere.
- Accepted trade-offs: up to one minute of beads writes can be lost if a
  container is reclaimed without a `git push`; sessions without the
  secret (or without DoltHub in the network policy) have no task graph
  and say so on every prompt; events are machine-local (#7039), so a
  fresh clone's `events` table is empty and `bd compact`/`bd flatten`
  must never run; background-process survival across turns is not
  documented by Claude Code and is unverified at adoption time.
- New external dependency: DoltHub availability and the account's key.

## References

- [`../2026-11-28-300.md`](../2026-11-28-300.md) — the source retrospective.
- `ai/beads-dolthub.md` — the mechanism; `ai/beads-dolthub-migration-handoff.md` Parts 5–6 — design and migration record.
- `ai/beads-server-mode-onboarding.md` — the same design generalised for other repositories.
- PR #300 (`scripts/beads-server.sh`, `tests/unit/test_beads_server.sh`).
