# Open issues

Registered debt now lives in the beads issue graph, synced through this
repository's `beads-dolt-data` branch (`ai/beads-dolt-git-remotes.md`):

```bash
bd ready            # unblocked work
bd list -t bug      # every registered defect
bd create "symptom" -t bug   # register a new undiagnosed failure:
                             # symptom, evidence, ruled-out, next step
```

The classification of every pre-beads issue (defect / feature / hygiene /
owner-deferred) is in `ai/roadmap.md`. The full pre-beads register, with
the rationale record for resolved entries, is archived verbatim at
`docs/archive/open-issues-2026-09-08.md`.
