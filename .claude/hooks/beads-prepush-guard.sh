#!/bin/bash
# PreToolUse hook (matcher: Bash). If the command about to run is a `git
# push`, first run one `bd sync` so code and task state leave the sandbox
# together, closing the background loop's one-minute window (owner,
# 2026-11-28). Everything else passes through untouched.
#
#   bd sync 0 (synced)            -> allow
#   bd sync 3 (transient)         -> allow with a warning; the loop retries
#   bd sync 1/2/4 (error, merge
#     conflict, stuck working set) -> block (exit 2) with the reason
#   beads unavailable this session
#     (no server / no key)        -> allow with a warning: nothing can be
#                                    stranded that was never written
#   shared sandbox                -> allow: its own sync runs elsewhere
set -uo pipefail
REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
case "$cmd" in
  *"git push"*|*"git  push"*) ;;
  *) exit 0 ;;
esac
SCRIPT="${REPO_DIR}/scripts/beads-server.sh"
[ -f "$SCRIPT" ] && [ -d "${REPO_DIR}/.beads" ] || exit 0
[ -d "$HOME/.local/state/ai-sandbox" ] && exit 0
line=$(bash "$SCRIPT" status 2>/dev/null)
case "$line" in
  "beads: ready="*) ;;
  *) echo "beads-prepush-guard: ${line:-beads unavailable}; pushing code without a beads sync." >&2
     exit 0 ;;
esac
bash "$SCRIPT" sync-now
rc=$?
case "$rc" in
  0) exit 0 ;;
  3) echo "beads-prepush-guard: bd sync transient failure (3); the background loop retries. Allowing the push." >&2; exit 0 ;;
  2) echo "beads-prepush-guard: bd sync hit a MERGE CONFLICT (2), nothing pushed. Resolve it by hand before pushing code." >&2 ;;
  4) echo "beads-prepush-guard: bd sync STUCK WORKING SET (4), nothing pushed. Clear it before pushing code." >&2 ;;
  *) echo "beads-prepush-guard: bd sync FAILED ($rc). Fix it before pushing code; log: /home/user/.beads-dolt/sync-loop.log" >&2 ;;
esac
exit 2
