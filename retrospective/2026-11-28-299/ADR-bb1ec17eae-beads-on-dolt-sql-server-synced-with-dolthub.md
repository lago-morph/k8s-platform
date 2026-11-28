# ADR: Beads runs on an operator-managed dolt sql-server synced with DoltHub, never a second server

- **ID**: ADR-bb1ec17eae
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-11-28
- **Source retrospective**: ../2026-11-28-299.md
- **PRs covered**: #298, #299 (design); #300 (implementation, another session)

## Context

Until 2026-11-28, the `kp` task graph ran in bd 1.2.2 **embedded** mode. Its Dolt data sat on the git **branch** `beads-dolt-data` of this repository, because the sandbox proxy refuses pushes to the default ref `refs/dolt/data`. Keeping that working took a 214-line helper (`scripts/beads-sync.sh`) and four Claude Code hooks:
- `params.git_ref` was hand-written into `.dolt/repo_state.json` before every push and pull.
- Fresh clones were bootstrapped through a throwaway local mirror, because `bd bootstrap` hardcodes `refs/dolt/data`.
- Pushes ran on every turn end, on compaction, and before every `git push`.

The owner wanted to move to the current bd release (1.3.4), running against a `dolt sql-server` with a private DoltHub database as the remote. That is the setup already used on the owner's own machine.

The session's research also surfaced constraints that make this a binding decision rather than a tactical one. All are cited to the v1.3.4 tag and the dolt v2.7.7 source:
- 1.3.x migrates the schema v53 → v66, and older binaries then refuse the database.
- 1.3.4 still has no option for a custom data ref.
- `events` becomes clone-local, so new events never replicate.
- `bd sync` adopts the git origin (GitHub) as its Dolt remote when none is configured.
- The `dolt_server_port` field in `metadata.json` is deprecated.
- The owner's shared sandboxes already run a managed beads server, and a second server on the same machine is unacceptable.

## Decision

The `kp` task graph lives in a dolt sql-server database named `k8s-platform`. It was migrated with bd's documented backup/restore route and is synced with a private DoltHub database, and bd never starts a server where one already runs.

- **Migration route.** bd 1.2.2 runs `bd backup init` and `bd backup sync`. bd 1.3.4 then runs `bd init --server --prefix kp --database k8s-platform` against the synced DoltHub database, followed by `bd backup restore --force`, `bd migrate schema --force`, `bd recompute-blocked` and `bd dolt push`. The data is verified bead by bead twice: once after the restore, and again after a fresh re-clone from DoltHub.
- **Versions.** bd 1.3.4 and dolt 2.7.7. Dolt publishes no checksums, so the SHA-256 is pinned in `versions.env`.
- **Connection.** Host, port and user come from `BEADS_DOLT_SERVER_*` environment variables and the gitignored `.beads/dolt-server.port`. `BEADS_DOLT_SERVER_MODE=1` marks the server as external. Nothing goes in `metadata.json`'s deprecated port field.
- **Sync.** Every minute, `bd sync` runs behind a PID guard with `BD_NO_REMOTE_ADOPT=1`. No per-turn hooks.
- **Shared sandboxes and foreign processes.** A start-up `detect` step comes first. If `~/.local/state/ai-sandbox` exists and a server answers at 127.0.1.1:3307 (`root`, no password) with no `beads-sync-HALTED` record, bd uses that server. In every other combination with the marker present, or if foreign `bd`/`dolt` processes run without the marker, the step sets nothing up and tells the user.
- **Archive.** `beads-dolt-data` and `__dolt_remote_info__` stay on GitHub as a frozen archive. The R2 bucket `k8s-platform-beads-2026-11-27` holds the 1.2.2 backups.

## Alternatives considered

- **Stay on embedded mode and upgrade in place to 1.3.4.** Rejected by the owner. The git-branch workarounds remain necessary in 1.3.4 and the `git_ref` trick was untested on its new Dolt engine. Every fresh-clone session would also hit the empty-events bug (#7039).
- **Copy the embedded Dolt directory into a server data dir and migrate it there.** This was the plan until the owner learned of the documented route. It is undocumented, and bd's own docs give `bd backup` + `bd init --server` + `bd backup restore` as the embedded→server path, which also preserves full history (v1.3.4 `docs/architecture/dolt.md:293-358`). Replaced by the documented route at the owner's direction.
- **Re-create the graph from the JSONL export (`bd export` → `bd import`).** Lower risk, but it loses Dolt history and events. The owner chose to keep history.
- **Use the beads pin, dolt 2.2.0.** The owner chose 2.7.7. Beads has not measured versions after 2.3.1, so the procedure runs beads' documented `DOLT_RESET('--hard')` check before migrating.
- **Use bd's `dolt.auto-push`** instead of a sync loop. It is not a timer: it pushes after write commands, at most once per interval, and does no pull. Rejected in favour of `bd sync` every minute.

## Consequences

- **Easier:** no hand-written Dolt remote state, no mirror bootstrap, and no per-turn push hooks. Machines share one DoltHub database, and the setup matches the owner's own machine.
- **Harder:**
  - Every cloud session needs the `DOLTHUB_CREDS_JWK` secret and network access to `www.dolthub.com` and `doltremoteapi.dolthub.com`. A session without them has no task graph and must say so on every prompt.
  - Up to one minute of beads writes can be lost if a container is reclaimed.
  - Whether a background process started from SessionStart stays alive is not documented by Claude Code and must be observed.
- **Accepted trade-offs:**
  - `events` no longer replicates, so `bd history --events` is per-machine. The 738 pre-migration events survive in the migrated copy's archive and the frozen branch.
  - Comment IDs were rekeyed by migration 0061.
  - Pre-existing dependency timestamps keep a 5–6 h local-time skew written by 1.2.2.
  - A DoltHub key can write to every database on the owner's account.

## References

- [`../2026-11-28-299.md`](../2026-11-28-299.md) — the source retrospective.
- `ai/beads-dolthub-migration-handoff.md` (merged in #298 and #299) — the full procedure, the verified facts with citations, and the Part 5 design.
- PRs the decision was made in: #298, #299. Implemented by #300 (`scripts/beads-server.sh`, `tests/unit/test_beads_server.sh`).
- Upstream: beads v1.3.4 `docs/architecture/dolt.md`, `internal/doltserver/doltserver.go:790-850`, `cmd/bd/backup_restore.go:105-120`; dolt v2.7.7 `go/libraries/doltcore/creds/jwk.go`.
