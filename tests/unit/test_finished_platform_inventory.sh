#!/usr/bin/env bash
# kp-2al.22: the finished-platform inventory is the oracle a human checks a
# build against, and step 3's "every installed component is healthy" criterion
# is defined by it. Its per-spoke Application rows had drifted to a `platform-`
# prefix that no cluster has ever produced: the ApplicationSets in
# argocd/apps/spoke/ name each generated Application
# `<short-name>-<component>`, and the platform services cluster registers with
# `shortName: spoke`, so the live names are `spoke-*`. A reader comparing the
# page to a real cluster found none of the names it listed.
#
# Nothing asserted the prefix, which is why it drifted. This derives the names
# from committed source and requires the page to carry each one.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

PAGE="docs/site/reference/finished-platform.md"
APPSET_DIR="argocd/apps/spoke"
SPOKE_XR="clusters/platform/spoke-access/spoke-access.yaml"

if ! command -v yq >/dev/null 2>&1; then
  echo "  (yq not installed — skipping)"
  assert_summary
fi

assert_file_exists() {
  if [ -f "$2" ]; then _pass "$1"; else _fail "$1" "missing: $2"; fi
}
assert_file_exists "page_exists" "$PAGE"
assert_file_exists "spoke_xr_exists" "$SPOKE_XR"

SHORT_NAME=$(yq eval-all 'select(.kind=="XSpokeAccess") | .spec.shortName' "$SPOKE_XR" 2>/dev/null | head -n 1)
if [ -n "$SHORT_NAME" ] && [ "$SHORT_NAME" != "null" ]; then
  _pass "short_name_read_from_source ($SHORT_NAME)"
else
  _fail "short_name_read_from_source" "could not read .spec.shortName from $SPOKE_XR"
fi

# Resolve each ApplicationSet's generated Application name. The template is
# either a literal or `{{index .metadata.labels "k8-platform.io/short-name"}}-<component>`.
expected=""
appsets=0
for f in "$APPSET_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  tmpl=$(yq eval-all 'select(.kind=="ApplicationSet") | .spec.template.metadata.name' "$f" 2>/dev/null | head -n 1)
  [ -n "$tmpl" ] && [ "$tmpl" != "null" ] || continue
  appsets=$((appsets + 1))
  case "$tmpl" in
    *'}}'*) name="$SHORT_NAME${tmpl##*\}\}}" ;;
    *)      name="$tmpl" ;;
  esac
  expected="$expected $name"
done

if [ "$appsets" -gt 0 ]; then
  _pass "appsets_found ($appsets in $APPSET_DIR)"
else
  _fail "appsets_found" "no ApplicationSets under $APPSET_DIR"
fi

missing=""
for name in $expected; do
  grep -qF "\`$name\`" "$PAGE" || missing="$missing $name"
done
if [ -z "$missing" ]; then
  _pass "every_generated_application_listed"
else
  _fail "every_generated_application_listed" \
    "$PAGE does not list:$missing"
fi

# And the stale form must not survive alongside the correct one: a page that
# carries both names is no more usable as an oracle than one carrying neither.
stale=""
for name in $expected; do
  case "$name" in
    "$SHORT_NAME"-*) ;;
    *) continue ;;                       # literal names have no prefix to stale
  esac
  suffix="${name#"$SHORT_NAME"-}"
  grep -qF "\`platform-$suffix\`" "$PAGE" && stale="$stale platform-$suffix"
done
if [ -z "$stale" ]; then
  _pass "no_stale_platform_prefixed_names"
else
  _fail "no_stale_platform_prefixed_names" "$PAGE still lists:$stale"
fi

assert_summary
