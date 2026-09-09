#!/bin/bash
# UserPromptSubmit hook: one line of beads status into the context on every
# prompt (ready / in-progress counts, unpushed yes/no) so the agent never
# has to remember to look.
set -uo pipefail
REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
command -v bd >/dev/null 2>&1 || exit 0
[ -d "${REPO_DIR}/.beads" ] || exit 0
bash "${REPO_DIR}/scripts/beads-sync.sh" status 2>/dev/null || true
exit 0
