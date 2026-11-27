#!/usr/bin/env bash
# Static "wired / gating / scoped" lint for the live-suite evidence producer
# (FINAL-PLAN §4.2 auto-013; burndown item 4). The live behavioral suite is only
# valuable if CI actually RUNS it, lets its exit code FAIL the build, and runs it
# under the scoped verifier/reaper role (not the admin job creds). The producer
# is a dedicated workflow (.github/workflows/live-verify.yml, like chainsaw.yml)
# whose body is .github/scripts/live-verify-run.sh. This lint makes all three
# properties mechanical so a future edit can't silently un-wire / neuter /
# privilege the producer without going RED here (the push/PR floor; ADR-0006).

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

WF=".github/workflows/live-verify.yml"
BODY=".github/scripts/live-verify-run.sh"

for f in "$WF" "$BODY"; do
  [ -f "$f" ] || { _fail "present_$f" "missing $f"; assert_summary; }
done

WF_TEXT="$(cat "$WF")"
BODY_TEXT="$(cat "$BODY")"

# 1. WIRED — the workflow invokes the producer body, and the body invokes the
#    live orchestrator. Both links must exist or the suite never runs in CI.
if printf '%s' "$WF_TEXT" | grep -qE 'live-verify-run\.sh' \
   && printf '%s' "$BODY_TEXT" | grep -qE 'tests/live/run\.sh'; then
  _pass "wired (live-verify.yml -> live-verify-run.sh -> tests/live/run.sh)"
else
  _fail "wired" "the live suite is not invoked end-to-end (workflow -> body -> run.sh)"
fi

# 2. GATING — build success is a function of run.sh's exit code: the invocation
#    is not neutralized with `|| true` or backgrounded with `&`.
if printf '%s' "$BODY_TEXT" | grep -E 'tests/live/run\.sh' | grep -qE '\|\|[[:space:]]*true|&[[:space:]]*$'; then
  _fail "gating_no_swallow" "the tests/live/run.sh invocation is neutralized (|| true / backgrounded &)"
else
  _pass "gating (run.sh exit code is not swallowed)"
fi

# 2b. GATING — no silent kill-switch in the workflow.
if printf '%s' "$WF_TEXT" | grep -qE '^\s*if:\s*false\b'; then
  _fail "gating_no_kill_switch" "live-verify.yml contains 'if: false' — the producer is silently disabled"
else
  _pass "gating (no 'if: false' kill-switch)"
fi

# 3. SCOPED — the suite runs under the assumed verifier/reaper role WITH the
#    required live-verify session tag, NOT the admin job creds.
if printf '%s' "$BODY_TEXT" | grep -qE 'sts[[:space:]]+assume-role' \
   && printf '%s' "$BODY_TEXT" | grep -qE 'live-verify'; then
  _pass "scoped (producer assumes the verifier/reaper role with a live-verify tag)"
else
  _fail "scoped" "no 'aws sts assume-role ... live-verify' — the suite must run scoped, not as admin"
fi

# 4. FULL VERDICT (kp-2al.37) — the producer runs every check: mutating for the
#    full profile, strict skips, the cluster identity wired for checks that
#    declare it, shared tunnels, and the workflow installs the SSM plugin.
if printf '%s' "$BODY_TEXT" | grep -qE 'LIVE_STRICT_SKIPS=1'; then
  _pass "full verdict: strict skips (unregistered skip is a FAIL)"
else
  _fail "full_verdict_strict" "producer does not export LIVE_STRICT_SKIPS=1"
fi
if printf '%s' "$BODY_TEXT" | grep -qE '^MODE="mutating"' \
   && printf '%s' "$BODY_TEXT" | grep -qE 'tests/live/run\.sh" "\$MODE"'; then
  _pass "full verdict: full profile runs mutating"
else
  _fail "full_verdict_mutating" "producer does not run tests/live/run.sh in mutating mode for the full profile"
fi
if printf '%s' "$BODY_TEXT" | grep -qE 'export LIVE_CLUSTER_AWS_PROFILE=' \
   && printf '%s' "$BODY_TEXT" | grep -qE 'export LIVE_SHARED_TUNNELS='; then
  _pass "full verdict: cluster identity + shared tunnels wired"
else
  _fail "full_verdict_identity" "producer lacks LIVE_CLUSTER_AWS_PROFILE / LIVE_SHARED_TUNNELS"
fi
# The cluster identity is a PROFILE for declared checks — the suite itself still
# runs under the assumed scoped role (assume-role precedes the run.sh call).
ar_line="$(grep -nE 'sts[[:space:]]+assume-role' "$BODY" | head -1 | cut -d: -f1)"
run_line="$(grep -nE 'tests/live/run\.sh"' "$BODY" | head -1 | cut -d: -f1)"
if [ -n "$ar_line" ] && [ -n "$run_line" ] && [ "$ar_line" -lt "$run_line" ]; then
  _pass "scoped by default (assume-role precedes run.sh; admin only via the declared profile)"
else
  _fail "scoped_by_default" "assume-role must precede the run.sh invocation"
fi
if printf '%s' "$WF_TEXT" | grep -qE 'session-manager-plugin'; then
  _pass "workflow installs the Session Manager plugin (relay)"
else
  _fail "workflow_ssm_plugin" "live-verify.yml does not install session-manager-plugin"
fi

assert_summary
