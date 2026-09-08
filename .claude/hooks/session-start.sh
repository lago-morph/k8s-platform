#!/bin/bash
# SessionStart hook — install the CI-pinned CLI toolchain at the start of
# every (remote/web) session so the agent is tool-ready immediately.
#
# The Claude-Code-on-the-web sandbox is ephemeral: each session starts with
# none of aws/argocd/helm/yq/crossplane installed, and the EKS kube-API is
# private-CA-blocked, so live ops depend on the argocd CLI + aws CLI being
# present from turn one. This hook delegates to scripts/sandbox-setup.sh
# (versions pinned in tests/chainsaw/versions.env) so the sandbox toolchain
# always matches CI. Idempotent: a tool already at the pinned version is a
# no-op, so re-runs (resume/clear/compact) are cheap.
set -uo pipefail

# Only touch the ephemeral remote sandbox; local dev machines manage their
# own toolchain (avoid writing to a developer's /usr/local/bin).
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if ! bash "${REPO_DIR}/scripts/sandbox-setup.sh"; then
  echo "session-start: sandbox-setup.sh reported a failure; some CLIs may be missing." >&2
  echo "session-start: re-run manually with: bash scripts/sandbox-setup.sh" >&2
fi

# Burndown item 5: surface stale-clone drift. The sandbox clones the repo once
# at container start, so a session can begin behind main — which has caused ADR
# number collisions and work based on stale code. Fetch main and warn (only)
# if the current checkout is behind it; rebase/merge before numbering ADRs or
# basing new work. Non-blocking — a network hiccup must never fail session start.
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
   && git -C "$REPO_DIR" fetch --quiet origin main 2>/dev/null; then
  behind=$(git -C "$REPO_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
  if [ "${behind:-0}" -gt 0 ]; then
    echo "session-start: WARNING — this checkout is ${behind} commit(s) behind origin/main." >&2
    echo "session-start: rebase/merge before numbering ADRs (scripts/next-adr-number.sh) or basing new work." >&2
  fi
fi

# Never block session start on a transient install/network hiccup — the
# agent runs scripts/whereami.sh first (AGENTS §8.1) and will see anything missing.
exit 0

# Beads (the task graph, ai/roadmap.md): install the pinned bd, pull the
# Dolt data from the beads-dolt-data branch (bootstrap on a fresh clone),
# then print the workflow context. Hooks, not instructions, keep the graph
# in sync (owner direction 2026-09-08; mechanics in
# ai/beads-dolt-git-remotes.md). Non-fatal: a beads failure must never
# break session start, but it is printed loudly.
if [ -f "${REPO_DIR}/scripts/beads-sync.sh" ]; then
  if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    bash "${REPO_DIR}/scripts/beads-sync.sh" install || echo "session-start: beads install FAILED" >&2
  fi
  if command -v bd >/dev/null 2>&1; then
    ( cd "${REPO_DIR}" && bash scripts/beads-sync.sh bootstrap ) || echo "session-start: beads bootstrap/pull FAILED — run: bash scripts/beads-sync.sh bootstrap" >&2
    ( cd "${REPO_DIR}" && bd prime 2>/dev/null ) || true
  fi
fi
