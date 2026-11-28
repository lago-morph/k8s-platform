---
name: beads
description: >-
  How this repository uses beads (bd) as its task graph: what is tracked,
  how to claim and close work with evidence, what the hooks already do for
  you (install, serve, sync, status, on an ai-sandbox host and in a cloud
  sandbox), and the MVP/v2.0 rule for new work.
  Trigger phrases: "bd ready", "claim a bead", "close the bead", "what's
  next", "add a task", "where is the plan", "v2.0 bucket".
allowed-tools:
  - Bash
  - Read
---

# beads in this repository

The plan lives in three places that must agree: `ai/roadmap.md` (steps and
the MVP criterion), `ai/handoff.md` (verified state), and the beads graph
(the tasks; prefix `kp`). `ai/beads-dolthub.md` explains the mechanics.

<!-- beads-kit:begin (managed by ai-sandbox-beads-repo-kit; edits here are overwritten, write repo rules below the end marker) -->
## How beads runs here (the same in every repository with this kit)

The task graph is a Dolt database on DoltHub, `k8s-platform` (`sync.remote` in `.beads/config.yaml`,
`dolt_database` in `.beads/metadata.json`). Every session reaches it in one of two ways, and
`.claude/beads/beads.sh` picks the way at session start. **Never configure bd by hand.**

| | ai-sandbox host | Cloud sandbox (or any other machine) |
|---|---|---|
| How to tell | `ai-sandbox-beads-status` is on PATH | it isn't |
| Server | ai-sandbox's shared server, 127.0.1.1:3307, every repo's database | one this session starts, 127.0.0.1:3307, this repo's only |
| Sync with DoltHub | the host, every minute (`ai-sandbox-beads-status`) | a background `bd sync` every minute, and one before every `git push` |
| Status line | `host-sync ok Ns ago` | `last-sync=<code> Ns ago` |
| When it's broken | the `beads-onboarding` skill (troubleshooting) | `bash .claude/beads/beads.sh setup`, which says why |

The hooks already do everything: SessionStart runs `.claude/beads/beads.sh session-start`, every
prompt shows the status line, and on a cloud sandbox every `git push` runs one `bd sync` first
(an error, merge conflict or stuck working set blocks the push).

**Never run:** `bd init`, `bd bootstrap`, `bd dolt start|stop|killall|push|pull`, `bd sync`,
`bd doctor --fix`, `bd migrate`, `bd compact`, `bd flatten`, `dolt sql-server`, `dolt clone`. Don't
write `.beads/.env` or change `.beads/metadata.json` / `.beads/config.yaml` (bd's own advice,
`bd doctor` and `bd prime` included). Don't kill bd or dolt processes you didn't start. If beads
is unavailable, there is no task graph this session: say so and carry on without it; never
work around it by hand.

**One place at a time.** The owner works either on the ai-sandbox host or in a cloud sandbox,
never both at once. Both sync with the same DoltHub database: if both wrote, the host stops its
server on purpose (it never merges by itself) and the owner sorts it out. Before the owner
switches, the last sync must be newer than the last write (the status line shows it).

**When `beads: UNAVAILABLE` or STOPPED ON PURPOSE:**
- ai-sandbox host: use the `beads-onboarding` skill. Only the owner restarts a stopped server.
- cloud sandbox: run `bash .claude/beads/beads.sh setup`. `no DoltHub key` means the cloud
  environment lacks the `DOLTHUB_CREDS_JWK` variable (or its network policy blocks
  doltremoteapi.dolthub.com): tell the owner. `FOREIGN bd/dolt PROCESSES`: report them; never
  kill them or start a second server.

**Who you are to bd.** The actor is git's `user.name` unless `--actor` is given: `Claude` in a
cloud sandbox, often the owner's name on the host. A bead assigned to someone else needs
`--actor <assignee>` to update or close; leave owner-only beads unassigned.

### Using it

```bash
bd ready                         # unblocked work
bd show <id>                     # details (--json shows text bd hides, like <placeholders>)
bd update <id> --claim           # take it before starting
bd create "title" -t task|bug|feature -p 0-4 [--parent <epic>] -d "description"
bd comments add <id> "note"
bd close <id> --reason "evidence: PR, run, output"
bd dep add <issue> <blocker>     # <issue> depends on <blocker>
```
<!-- beads-kit:end -->

# Rules for this repository

## Working a bead

1. `bd ready` → pick the highest-priority item that is yours to do.
2. `bd update <id> --claim` before touching anything.
3. Do the work. New findings become beads immediately:
   `bd create "<symptom>" -t bug -p N --parent <epic>` with symptom,
   evidence, ruled-out, next step in the description.
4. Close with evidence, never with "done":
   `bd close <id> --reason "<run ID / PR / oracle output>"`.
   The done-contract in `AGENTS.md` applies: clean-build or oracle evidence,
   or the status stays `pending clean-build verification`.
5. One session per bead. Two sessions editing the same bead cannot be
   merged; if you must hand over mid-bead, close or un-claim it first.

## The MVP rule for anything new (owner, 2026-09-09)

A scenario is testable if every step is self-service OR "raise a ticket,
an admin does something documented, continue". A gap that blocks testing
even with a ticket is fixed now. Everything else is a `feature` bead under
the v2.0 epic (`bd list -l v2.0`), re-evaluated in step 6. Do not build
v2.0 items early, even when the gap is obvious.

## One step at a time (owner rule, 2026-09-09)

Detailed planning happens one step at a time, with the owner, after the
previous step closes; each step epic has a GATE bead (label `gate`) that
every child depends on. Beads written ahead of that session are labelled
`sketch`: do not elaborate, split, or work them. Never define scenarios,
page lists, or task breakdowns for a future step. Any step that uses a
provisioned AWS account gets an owner bead "provision the account" that
blocks the first AWS-using task; docs and test-prep tasks never depend on it.

## Improving this skill

When you learn something that would have saved you time here (a bd flag,
a failure mode, a better habit), edit this file in the same PR (below the
managed block: the block itself is ai-sandbox's `modules/beads/repo-kit/skill-block.md`) and
tell the owner in your report what you changed and why. No permission
needed; the owner reviews it in the PR.

## Quick reference

```bash
bd ready                       bd show <id>            bd list --parent <epic>
bd update <id> --claim         bd close <id> --reason "..."
bd create "t" -t task|bug|feature|decision -p 0-4 --parent <epic> -l step-N
bd dep add <issue> <blocker>   # <issue> depends on <blocker>
bd list -l v2.0                # the deferred bucket
bash .claude/beads/beads.sh status|setup
```
Gotchas: `bd create --deps "blocks:<id>"` makes the NEW bead block `<id>`.
`bd show` (text) silently hides angle-bracket tokens like `<spoke>` in body
fields; the data is intact (`bd show --json`, `bd history`). Read beads
through `--json` when it matters and write placeholders as `SPOKE_CLUSTER`.
