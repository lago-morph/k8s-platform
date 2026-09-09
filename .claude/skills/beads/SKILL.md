---
name: beads
description: >-
  How this repository uses beads (bd) as its task graph: what is tracked,
  how to claim and close work with evidence, what the hooks already do for
  you (install, pull, push, status), and the MVP/v2.0 rule for new work.
  Trigger phrases: "bd ready", "claim a bead", "close the bead", "what's
  next", "add a task", "where is the plan", "v2.0 bucket".
allowed-tools:
  - Bash
  - Read
---

# beads in this repository

The plan lives in three places that must agree: `ai/roadmap.md` (steps and
the MVP criterion), `ai/handoff.md` (verified state), and the beads graph
(the tasks; prefix `kp`). Dolt data is on the branch `beads-dolt-data`;
`ai/beads-dolt-git-remotes.md` explains the mechanics.

## What the hooks already do (do not repeat by hand)

SessionStart installs the pinned `bd`, pulls the graph, prints a status
line and `bd ready`. Every prompt injects the status line. Every assistant
turn end (Stop), every compaction, and every `git push` push unpushed beads;
a failed beads push blocks the code push. You never run `bd dolt push`.

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
bash scripts/beads-sync.sh status|push|bootstrap
```
Gotchas: `bd create --deps "blocks:<id>"` makes the NEW bead block `<id>`.
`bd show` (text) silently hides angle-bracket tokens like `<spoke>` in body
fields; the data is intact (`bd show --json`, `bd history`). Read beads
through `--json` when it matters and write placeholders as `SPOKE_CLUSTER`.
