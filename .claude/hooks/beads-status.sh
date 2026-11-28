#!/bin/bash
# UserPromptSubmit hook: one line of beads status into the context on every
# prompt (ready / in-progress counts, last background sync and its age, or a
# loud UNAVAILABLE) so the agent never has to remember to look. Read-only:
# it runs no sync.
set -uo pipefail
REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -f "${REPO_DIR}/scripts/beads-server.sh" ] || exit 0
bash "${REPO_DIR}/scripts/beads-server.sh" status 2>/dev/null || true
exit 0
