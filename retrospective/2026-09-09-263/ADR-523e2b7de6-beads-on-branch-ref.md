# ADR: Beads task graph with Dolt data on a git branch ref, synced by hooks

- **ID**: ADR-523e2b7de6
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-09-09
- **Source retrospective**: ../2026-09-09-263.md
- **PRs covered**: #262, #263

## Context

The owner chose beads (bd) as the task graph for steps 3 onward, in its Dolt-backed storage mode with the git remote as the data store, so that no second credential is needed. The Claude Code web sandbox is ephemeral and its push credential refuses non-branch refs and branch deletions (HTTP 403 from the proxy, verified 2026-09-08), so beads' default data ref `refs/dolt/data` cannot be written from a session. bd 1.2.2 offers no option for a different ref, and `bd bootstrap` hardcodes the default. The owner also required that sync be driven by hooks rather than instructions, because instructions are not reliably followed and the plan must be stable.

## Decision

The project's task graph lives in beads with its Dolt database stored on the branch refs/heads/beads-dolt-data of the platform repository, kept in sync exclusively by Claude Code hooks (session start, Stop, PreCompact, and a pre-push guard) through scripts/beads-sync.sh.

Concretely: Dolt's per-remote `git_ref` parameter in `.beads/embeddeddolt/kp/.dolt/repo_state.json` points at the branch; the helper re-applies it before every push and pull because the file is untracked; fresh clones are bootstrapped through a throwaway local bare repository that holds the branch's data on `refs/dolt/data` so `bd bootstrap` accepts it; the remote URL is normalised to end in `.git`. Hooks: SessionStart installs the pinned `bd` from npm and bootstraps or pulls; Stop, PreCompact and SessionEnd push; a PreToolUse guard on Bash pushes beads before any `git push` and denies the push if that fails; UserPromptSubmit injects a status line. `bd prime` is not used because its generic close protocol conflicts with the repository's done-contract.

## Alternatives considered

- **DoltHub as the Dolt remote** — removes every workaround (`bd bootstrap` and `bd dolt push` work as documented) but needs a DoltHub token in every sandbox and its latency is unmeasured; deferred until the branch-ref approach proves insufficient.
- **Markdown-only plan, beads unused** — reviewable but loses dependency-aware `bd ready` and the orchestrator pattern the owner wants to learn; rejected, with the plan snapshot renderer proposed to restore reviewability.
- **`bd setup claude` and `bd hooks install`** — the former rewrites `settings.json` wholesale and appends a managed block to `CLAUDE.md`; the latter's export hook adds commit noise; both rejected in favour of hand-written hooks.
- **Several sandboxes with independent sessions** — the same-bead conflict is unrecoverable in bd 1.2.2 and the claim only leaves the sandbox at turn end; rejected in favour of one orchestrator session with subagents in worktrees, so there is one writer per graph.

## Consequences

Easier: a fresh session starts with the graph pulled and the ready queue printed; task state is never more than one turn behind origin; code and task state leave the sandbox together. Harder: two Dolt-owned branches (`beads-dolt-data`, `__dolt_remote_info__`) sit in the branch list and must be excluded from branch automation and never protected against force pushes; the mechanism rests on an undocumented Dolt parameter and a mirror bootstrap that must be re-validated on every `bd` upgrade (the version is pinned in `versions.env`); a plan in beads is not reviewable as a document without a renderer. Accepted trade-off: workaround complexity in one script versus a second credential in every sandbox.

## References

- [`../2026-09-09-263.md`](../2026-09-09-263.md) — the source retrospective.
- [`./SKILL-SPEC-8c93458f51-beads-plan-review.md`](./SKILL-SPEC-8c93458f51-beads-plan-review.md) — the reviewability counterpart.
- `ai/beads-dolt-git-remotes.md` §4 — the experiment record; `scripts/beads-sync.sh`; `.claude/settings.json`.
- PRs the decision was made in: #262 (notes), #263 (implementation).
