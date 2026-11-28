---
name: beads
description: >-
  How this repository uses beads (bd) as its task graph: what is tracked,
  how to claim and close work with evidence, what the hooks already do for
  you (install, serve, sync, status), and the MVP/v2.0 rule for new work.
  Trigger phrases: "bd ready", "claim a bead", "close the bead", "what's
  next", "add a task", "where is the plan", "v2.0 bucket".
allowed-tools:
  - Bash
  - Read
---

# beads in this repository

The plan lives in three places that must agree: `ai/roadmap.md` (steps and
the MVP criterion), `ai/handoff.md` (verified state), and the beads graph
(the tasks; prefix `kp`). The Dolt data is in a private DoltHub database
(`sync.remote` in `.beads/config.yaml`); `ai/beads-dolthub.md` explains the
mechanics.

## What the hooks already do (do not repeat by hand)

SessionStart runs `scripts/beads-server.sh setup`: it installs the pinned
`bd` and `dolt`, imports the DoltHub key, starts a local `dolt sql-server`
(127.0.0.1:3307), clones the database with `bd bootstrap` when missing, and
starts a background `bd sync` every 60 s. Then it prints a status line and
`bd ready`. Every prompt injects the status line (`last-sync=<code> <age>`).
Every `git push` first runs one `bd sync`; error, merge conflict or a stuck
working set blocks the code push. You never run `bd dolt push` or `bd sync`
by hand, and never `bd compact` / `bd flatten` (events are machine-local).

On a **shared sandbox** (`~/.local/state/ai-sandbox` exists) the server at
127.0.1.1:3307 is managed outside this repo: setup points bd at it, clones
this repo's database into it with `bd bootstrap` if it is missing, and
installs, starts and syncs nothing. A failed clone (for example, no DoltHub
key on that server) is printed and setup exits non-zero. If bd or dolt processes it did not
start are running on an ordinary machine, setup sets up nothing and says so.

## If the status line says `beads: UNAVAILABLE`

The reason is on the line. Recovery, in order:

```bash
bash scripts/beads-server.sh setup    # re-run it; it prints why it failed
bd ready                              # confirm the graph is back
```

- `no DoltHub key`: the environment lacks the `DOLTHUB_CREDS_JWK` secret.
  Tell the owner; there is no task graph this session.
- `FOREIGN bd/dolt PROCESSES`: stop and report the listed processes to
  the owner. Never kill them or start a second server.
- `SHARED SANDBOX BEADS CONFIG IS BROKEN`: report it with the named check
  and `~/.local/state/ai-sandbox/beads-sync.log`. Do not try to repair it.
- `bd X installed, versions.env pins Y`: re-run setup (it installs the pin).
- Never clone the database with a plain `dolt clone`: it lacks bd's
  machine-local tables and bd fails with `table not found: leases`.
  `bd bootstrap` is the only supported clone.

Never work around a dead graph by editing beads by hand or by bypassing the
pre-push sync.

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
a failure mode, a better habit), edit this file directly in the same PR and
tell the owner in your report what you changed and why. No permission
needed; the owner reviews it in the PR.

## Quick reference

```bash
bd ready                       bd show <id>            bd list --parent <epic>
bd update <id> --claim         bd close <id> --reason "..."
bd create "t" -t task|bug|feature|decision -p 0-4 --parent <epic> -l step-N
bd dep add <issue> <blocker>   # <issue> depends on <blocker>
bd list -l v2.0                # the deferred bucket
bash scripts/beads-server.sh status|setup|sync-now
```
Gotchas: `bd create --deps "blocks:<id>"` makes the NEW bead block `<id>`.
`bd show` (text) silently hides angle-bracket tokens like `<spoke>` in body
fields; the data is intact (`bd show --json`, `bd history`). Read beads
through `--json` when it matters and write placeholders as `SPOKE_CLUSTER`.
