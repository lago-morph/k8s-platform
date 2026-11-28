# .claude/beads: the beads kit

Written by ai-sandbox's `ai-sandbox-beads-repo-kit` (modules/beads/README.md, "The repo kit" in the
ai-sandbox repository). Don't edit these files here: changes are overwritten when the kit is
refreshed. `beads.sh` runs beads (bd) for this repository on an ai-sandbox host and in a cloud
sandbox; `versions.env` pins the bd and dolt it uses. How to use it: `.claude/skills/beads/SKILL.md`.

A cloud sandbox needs, in its environment settings: the variable `DOLTHUB_CREDS_JWK` (the
DoltHub key, a JWK), and network access to doltremoteapi.dolthub.com, registry.npmjs.org and
github.com (release downloads).
