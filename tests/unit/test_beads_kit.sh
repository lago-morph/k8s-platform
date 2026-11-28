#!/usr/bin/env bash
# The beads wiring is ai-sandbox's repo kit (.claude/beads/, written by
# ai-sandbox-beads-repo-kit; its logic is tested in the ai-sandbox repo).
# This checks the kit is wired into this repository and the pre-kit setup
# is gone:
#   - .claude/beads/beads.sh parses and is shellcheck-clean
#   - the pins live in .claude/beads/versions.env, not the root versions.env
#   - settings.json runs the kit's three hooks, and no other beads hook
#   - metadata.json is in bd's own format (bd bootstrap rewrites it so)
#   - no tracked file outside the archives references the pre-kit scripts
#     or the old git-branch setup
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. "$(dirname "$0")/lib/test-helpers.sh"

KIT=.claude/beads/beads.sh
if bash -n "$KIT"; then pass "bash -n $KIT"; else fail "bash -n $KIT"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if out=$(shellcheck -S warning "$KIT" .claude/hooks/session-start.sh 2>&1); then pass "shellcheck kit + session-start"; else fail "shellcheck kit + session-start" "$out"; fi
elif [ "${CI:-}" = "true" ]; then
  fail "shellcheck" "shellcheck missing on CI"
fi

if grep -qE '^BD_VERSION="[0-9.]+"$' .claude/beads/versions.env && ! grep -q '^BD_VERSION=' versions.env; then
  pass "bd pin only in .claude/beads/versions.env"
else
  fail "bd pin only in .claude/beads/versions.env"
fi

hooks=$(python3 -c '
import json
s = json.load(open(".claude/settings.json"))
for ev, groups in s.get("hooks", {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            print(ev, h.get("command", ""))')
for want in "SessionStart .*beads.sh\" session-start" "UserPromptSubmit .*beads.sh\" status" "PreToolUse .*beads.sh\" prepush-hook"; do
  if printf '%s\n' "$hooks" | grep -q "$want"; then pass "hook: $want"; else fail "hook: $want" "$hooks"; fi
done
if printf '%s\n' "$hooks" | grep -E 'beads' | grep -vq '.claude/beads/beads.sh'; then
  fail "no beads hook other than the kit's" "$hooks"
else
  pass "no beads hook other than the kit's"
fi

want=$(python3 -c 'import json; m=json.load(open(".beads/metadata.json")); print(json.dumps(m, indent=2), end="")')
if [ "$want" = "$(cat .beads/metadata.json)" ]; then pass "metadata.json in bd's format"; else fail "metadata.json in bd's format"; fi

refs=$(git ls-files -z | xargs -0 grep -lE 'scripts/beads-server\.sh|beads-status\.sh|beads-prepush-guard|beads-sync\.sh|beads-dolt-data|embeddeddolt' 2>/dev/null \
  | grep -vE '^(docs/archive/|retrospective/|ai/LESSONS\.md$|ai/beads-dolthub-migration-handoff\.md$|ai/beads-server-mode-onboarding\.md$|\.beads/\.gitignore$|tests/unit/test_beads_kit\.sh$)' || true)
if [ -z "$refs" ]; then
  pass "no tracked file outside the archives references the pre-kit setup"
else
  fail "no tracked file outside the archives references the pre-kit setup" "$(echo "$refs" | tr '\n' ' ')"
fi

summary
