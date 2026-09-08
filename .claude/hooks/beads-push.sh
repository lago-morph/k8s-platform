#!/bin/bash
# SessionEnd / PreCompact hook: push unpushed beads (Dolt) commits so task
# state survives the ephemeral sandbox. Best effort on exit (a hook cannot
# stop a session ending); failures are printed for the transcript.
set -uo pipefail
REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
command -v bd >/dev/null 2>&1 || exit 0
[ -d "${REPO_DIR}/.beads" ] || exit 0
bash "${REPO_DIR}/scripts/beads-sync.sh" push || echo "beads-push: push failed; task state may be unsynced" >&2
exit 0
