# .beads — the task graph's workspace (server mode)

This repository's beads graph (prefix `kp`) lives in the DoltHub database
named by `sync.remote` in `config.yaml`. Nothing in this directory holds
issue data; the tracked files only say where the data is:

| File | Meaning |
|---|---|
| `metadata.json` | `dolt_mode: server`, `dolt_database: k8s-platform`, the `project_id`. No host, port or user. |
| `config.yaml` | `sync.remote`: the DoltHub URL. |
| `.gitignore` | Machine-local files bd and `scripts/beads-server.sh` write here. |

At session start `scripts/beads-server.sh setup` starts a local
`dolt sql-server`, runs `bd bootstrap` to clone the database from DoltHub
when it is missing, and runs `bd sync` every 60 s in the background. See
`ai/beads-dolthub.md`.

Never run `bd compact` or `bd flatten`: events are machine-local since
schema migration 0062, and a fresh clone's `events` table is empty.
