#!/bin/bash
# PreToolUse hook (matcher: Bash). If the command about to run is a `git
# push`, first push the beads issue graph (Dolt data on the beads-dolt-data
# branch). Code and task state then leave the sandbox together; a failed
# beads push blocks the code push (exit 2 = deny with reason) so unsynced
# task state can never be stranded behind a merged PR. Everything else
# passes through untouched. Deterministic by construction: no agent
# instruction is involved (owner direction 2026-09-08).
set -uo pipefail
REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
case "$cmd" in
  *"git push"*|*"git  push"*) ;;
  *) exit 0 ;;
esac
# Not a beads-enabled checkout (no sync script or no .beads/): pass through.
[ -f "${REPO_DIR}/scripts/beads-sync.sh" ] && [ -d "${REPO_DIR}/.beads" ] || exit 0
if ! command -v bd >/dev/null 2>&1; then
  echo "beads-prepush-guard: bd not installed; run: bash scripts/beads-sync.sh install" >&2
  exit 2
fi
if ! bash "${REPO_DIR}/scripts/beads-sync.sh" push >&2; then
  echo "beads-prepush-guard: beads push FAILED — fix the beads sync (bd dolt pull, resolve, bd dolt push) before pushing code." >&2
  exit 2
fi
exit 0
