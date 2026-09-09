#!/bin/bash
# Stop / PreCompact / SessionEnd hook: push unpushed beads (Dolt) commits so
# task state is never more than one turn behind origin. Stop fires after every
# assistant turn (cheap: 0.15 s when nothing to push); SessionEnd is best
# effort only — a reclaimed sandbox never runs it. Failures are printed.
set -uo pipefail
REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
command -v bd >/dev/null 2>&1 || exit 0
[ -d "${REPO_DIR}/.beads" ] || exit 0
bash "${REPO_DIR}/scripts/beads-sync.sh" push || echo "beads-push: push failed; task state may be unsynced" >&2
exit 0
