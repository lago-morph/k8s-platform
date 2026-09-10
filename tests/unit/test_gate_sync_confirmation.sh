#!/usr/bin/env bash
# kp-2al.24: keep the vacuous gate-sync confirmation from coming back.
#
# The bring-up page and the clean-build recipe used to tell an operator to
# confirm a gate had synced at an intended SHA by reading
# `.status.sync.revision`. Argo CD populates that field from the target
# revision it has OBSERVED in the repository, not from a completed sync
# operation. Measured on build #7: `spoke-access` already reported the right
# SHA there while still OutOfSync with no operation in its history — so the
# check passed for a gate that had never synced at all, which is precisely
# the failure it existed to catch. Build #6's readiness evidence cited the
# same weak check.
#
# The corrected instruction reads the operation instead
# (`.status.operationState.phase` == Succeeded plus
# `.status.operationState.syncResult.revision` == the SHA). This lint holds
# that correction in place: operator-facing guidance may still MENTION
# `.status.sync.revision` — the bring-up page mentions it precisely to warn
# against it, and reading it on `bootstrap` to learn which revision the
# repo-server is serving is a legitimately different question — but a file
# that mentions it must also carry the operationState check, so the stronger
# check is never simply absent.
#
# Exemption (inline, same line, reason required):
#   noqa: sync-revision - <reason>
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

WEAK='\.status\.sync\.revision'
STRONG='\.status\.operationState'
MARKER_RE='[Nn][Oo][Qq][Aa]:[[:space:]]*sync-revision'
SCAN_DIRS=(docs/site ai/recipes)

# file_is_clean <path> — prints OK | MISSING_STRONG | NO_REASON
file_is_clean() {
  local f="$1"
  local hits exempt total
  hits=$(grep -nE "$WEAK" "$f" 2>/dev/null)
  [ -z "$hits" ] && { echo OK; return; }
  total=$(printf '%s\n' "$hits" | grep -c .)
  exempt=$(printf '%s\n' "$hits" | grep -cE "$MARKER_RE")
  if [ "$exempt" -gt 0 ] && [ "$exempt" -eq "$total" ]; then
    # Every mention is exempted; each exemption still needs a reason.
    if printf '%s\n' "$hits" | grep -E "$MARKER_RE" \
         | sed -E "s/.*${MARKER_RE}[[:space:]]*-?[[:space:]]*//; s/-->.*$//" \
         | grep -qv '[A-Za-z]'; then
      echo NO_REASON
    else
      echo OK
    fi
    return
  fi
  if grep -qE "$STRONG" "$f" 2>/dev/null; then
    echo OK
  else
    echo MISSING_STRONG
  fi
}

# ---------------------------------------------------------------------------
# Test 1: the lint's own logic, against synthetic files
# ---------------------------------------------------------------------------
echo "── test 1: lint logic ──"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/bad.md" <<'EOF'
Confirm the gate synced:
`kubectl -n argocd get application platform-cluster-claim -o jsonpath='{.status.sync.revision}'`
If that value is not your SHA, stop.
EOF
assert_eq "lint_catches_weak_check_alone" "MISSING_STRONG" "$(file_is_clean "$TMP/bad.md")"

cat > "$TMP/good.md" <<'EOF'
Confirm the gate completed a sync operation:
`{.status.operationState.phase}{.status.operationState.syncResult.revision}`
Do not check `.status.sync.revision` instead — it proves nothing.
EOF
assert_eq "lint_passes_when_strong_check_present" "OK" "$(file_is_clean "$TMP/good.md")"

cat > "$TMP/nomention.md" <<'EOF'
Nothing about Argo CD sync fields at all.
EOF
assert_eq "lint_passes_file_without_the_field" "OK" "$(file_is_clean "$TMP/nomention.md")"

cat > "$TMP/exempt.md" <<'EOF'
Display only: `.status.sync.revision` <!-- noqa: sync-revision - a status column, not a sync proof -->
EOF
assert_eq "lint_honours_exemption_with_reason" "OK" "$(file_is_clean "$TMP/exempt.md")"

cat > "$TMP/exempt-bare.md" <<'EOF'
Display only: `.status.sync.revision` <!-- noqa: sync-revision -->
EOF
assert_eq "lint_rejects_exemption_without_reason" "NO_REASON" "$(file_is_clean "$TMP/exempt-bare.md")"

# ---------------------------------------------------------------------------
# Test 2: the tracked tree is clean (audit-before-enforce)
# ---------------------------------------------------------------------------
echo "── test 2: tracked operator guidance is clean ──"
violations=""
scanned=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  verdict=$(file_is_clean "$f")
  [ "$verdict" = "OK" ] || violations="$violations
  $f: $verdict"
done < <(git ls-files "${SCAN_DIRS[@]}" 2>/dev/null | grep -E '\.(md|sh)$')

if [ "$scanned" -gt 0 ]; then
  _pass "scan_reached_files ($scanned scanned)"
else
  _fail "scan_reached_files" "git ls-files matched nothing under ${SCAN_DIRS[*]}"
fi

if [ -z "$violations" ]; then
  _pass "no_vacuous_gate_sync_confirmation"
else
  _fail "no_vacuous_gate_sync_confirmation" \
    "these files read .status.sync.revision without the operationState check:$violations"
fi

assert_summary
