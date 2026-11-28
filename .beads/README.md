# .beads — the task graph's workspace (server mode)

This repository's beads graph (prefix `kp`) lives in the DoltHub database
named by `sync.remote` in `config.yaml`. Nothing in this directory holds
issue data; the tracked files only say where the data is:

| File | Meaning |
|---|---|
| `metadata.json` | `dolt_mode: server`, `dolt_database: k8s-platform`, the `project_id`. No host, port or user. |
| `config.yaml` | `sync.remote`: the DoltHub URL. |
| `.gitignore` | Machine-local files bd and `.claude/beads/beads.sh` write here. |

At session start `.claude/beads/beads.sh session-start` (ai-sandbox's repo
kit) connects bd to the database: on an ai-sandbox host, the host's shared
server; in a cloud sandbox, a local `dolt sql-server` it starts, cloning the
database with `bd bootstrap` and running `bd sync` every 60 s. See
`.claude/skills/beads/SKILL.md` and `ai/beads-dolthub.md`.

Never run `bd compact` or `bd flatten`: events are machine-local since
schema migration 0062, and a fresh clone's `events` table is empty.
