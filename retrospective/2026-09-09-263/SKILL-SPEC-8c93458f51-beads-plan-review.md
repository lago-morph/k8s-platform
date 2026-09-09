# Spec: `beads-plan-review`

- **ID**: SKILL-SPEC-8c93458f51
- **Source retrospective**: ../2026-09-09-263.md

## Intent

Render the beads task graph into one reviewable markdown document (every bead's description, acceptance criteria, notes, labels, assignee, and its blocking edges in both directions, grouped by epic) so the owner can review a plan that lives in beads the way they would review a document, and so a planning PR can carry a diffable snapshot. Grounded in the 2026-09-09 session: the owner could not assess whether to trust the session because the plan was only visible through bd commands, and the first ad-hoc rendering silently omitted every dependency edge because bd list --json does not carry blocking edges.

## Trigger

Direct: "show me the plan", "render the beads", "plan snapshot", "dump the beads", "I can't review the plan", "/beads-plan-review". Proactive: before opening or updating any PR whose commits changed the beads graph (seed, restructure, reparent, gate changes), and whenever the owner is asked to ratify a classification or a step plan. Negative: not for a single bead (`bd show --json <id>` suffices) and not as a substitute for `bd ready` in routine work.

## Inputs

A checkout with `.beads/` bootstrapped (the session-start hook does this), `bd` on PATH, and optionally an epic filter (`--epic kp-2al`) or a label filter (`--label v2.0`). No arguments renders the whole graph.

## Outputs

`ai/plan-snapshot.md` (or a path the caller names): one markdown document, grouped by epic in roadmap order, one card per bead with title, ID, type, priority, status, assignee, labels, description, acceptance criteria, notes, and two edge lists: *depends on* and *blocks*, both directional. A header line records the render time and the Dolt head so a reader knows what version they are looking at. When run for a PR, the file is committed with the graph change.

## Workflow

1. Read the graph through `bd show --json <id>` for every bead, not `bd list --json`: the list output omits blocking edges (verified 2026-09-09: `bd list --json` carried a `dependencies` field on 45 beads that held only parent-child links; all 39 blocking edges appeared only in `bd show --json`). Collect open, closed, deferred, and in_progress statuses explicitly; `bd list --json` defaults to open.
2. Build the edge index from each bead's `dependencies[]` entries with `dependency_type == "blocks"`; record both directions so each card can show *depends on* and *blocks*.
3. Order epics by the roadmap step order (`kp-2al`, `kp-cm3`, `kp-e5n`, `kp-zab`, `kp-yif`, `kp-caz`), children by priority then ID, then a final section for unparented beads.
4. Render each card. Never pass body text through a terminal renderer; angle-bracket tokens such as `<spoke>` survive in JSON and must appear verbatim in the document.
5. Append a summary table: beads per epic, ready count (`bd ready --json`), gate beads and their state, `sketch`-labelled count.
6. Self-check before delivering: assert the rendered edge count equals the edge-index size and is non-zero when the graph has any blocking edge; assert every bead ID from step 1 appears exactly once. Fail loudly on either.
7. Deliver the file (send it to the owner, or commit it alongside the graph change).

## Concrete examples

### Example 1: the review request that exposed the gap

The owner asked to see the plan after step 2. The first rendering was built from `bd list --json`; it grouped 49 beads correctly but printed no "depends on" lines at all. The owner asked "Are there no dependencies, or were they simply not rendered?" A check of the same export showed the field the renderer read was never populated with blocking edges, while `bd dep list kp-2al.2` showed the edge to `kp-2al.1`. With this skill's step 1 and step 6, the render would have failed its own assertion before being sent.

### Example 2: reviewing a restructure before merge

After the owner's decisions of 2026-09-09 (Kyverno to v2.0, cleanup step, gates for steps 4 to 7), 55 beads and 39 edges changed. Running the skill with no filter produces the document; the section for `kp-2al` shows the chain `kp-2al.18 (owner account) → kp-2al.1 → kp-2al.2 → kp-2al.3 → kp-cm3.5 (gate)` as explicit *blocks* and *depends on* lines on each card, and the `v2.0` epic lists its seven children with their labels. The file is attached to the PR so the reviewer reads the plan as a document instead of running bd.

## Anti-patterns

- **Rendering from `bd list --json`**. It silently drops blocking edges (2026-09-09).
- **Rendering body text through `bd show` text output**. It hides `<token>` strings; the owner read that as data loss.
- **Delivering without the self-check**. A document with zero edges was delivered as "the plan" once; the assertion in step 6 makes that impossible.
- **Hand-editing the snapshot**. It is generated; edits go into beads and the file is regenerated.

## Acceptance criteria

- [ ] Every bead in the graph appears exactly once, with all content fields and both edge directions.
- [ ] Rendered edge count equals the number of blocking edges reported by `bd show --json` across the graph; the script exits non-zero if they differ.
- [ ] Angle-bracket tokens in descriptions appear verbatim.
- [ ] A unit test renders a fixture graph with one blocking edge and asserts the edge line is present (the R5 remedy in the source retrospective).
- [ ] Runs in under ten seconds on a 60-bead graph.

## Files this skill creates / modifies

- `scripts/beads-snapshot.sh` — the renderer (bash plus python3, no other dependencies).
- `tests/unit/test_beads_snapshot.sh` — the fixture-graph test for edge rendering.
- `ai/plan-snapshot.md` — the generated document, committed with graph changes.
- `.claude/skills/beads-plan-review/SKILL.md` — the skill file.
