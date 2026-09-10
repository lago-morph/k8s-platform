#!/usr/bin/env bash
# kp-2al.16 — scenario-ready check for the database ticket runbook.
#
# Under the MVP criterion a tenant database is documentation, not a feature:
# tenants cannot place an XDatabase on the management cluster, so an admin does
# it on request and the credentials cross to the spoke through Secrets Manager.
# docs/site/how-to/fulfil-a-database-request.md is that admin runbook, and a
# step-5 scenario author automates directly from its manifests.
#
# "Scenario-ready" means those manifests are still true of the platform: their
# kinds and fields match the committed XRD and the committed Keycloak
# precedent they were derived from, and — the property most likely to break
# silently — the admin half and the tenant half address the SAME Secrets
# Manager path. A page whose two halves disagree reads perfectly and cannot
# work, and nothing else in the suite looks at it.
#
# Offline: yq over committed files only. No cluster, no AWS.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

PAGE="docs/site/how-to/fulfil-a-database-request.md"
XRD="crossplane/xrds/xdatabase.yaml"
KC_PUSH="platform-services/keycloak/database/keycloak-db-pushsecret.yaml"
KC_PULL="platform-services/keycloak/spoke/keycloak-db-externalsecret.yaml"

if ! command -v yq >/dev/null 2>&1; then
  echo "  (yq not installed — skipping)"
  assert_summary
fi

for f in "$PAGE" "$XRD" "$KC_PUSH" "$KC_PULL"; do
  if [ -f "$f" ]; then _pass "source_present: $f"; else _fail "source_present: $f" "missing"; fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Extract every fenced ```yaml block from the page, one file per block.
# ---------------------------------------------------------------------------
awk -v out="$WORK" '
  /^```yaml[[:space:]]*$/ { inblk=1; n++; next }
  /^```[[:space:]]*$/     { inblk=0; next }
  inblk                   { print >> (out "/block-" n ".yaml") }
' "$PAGE"

blocks=$(find "$WORK" -name 'block-*.yaml' | wc -l)
if [ "$blocks" -gt 0 ]; then
  _pass "page_has_yaml_manifests ($blocks blocks)"
else
  _fail "page_has_yaml_manifests" "no fenced yaml blocks found in $PAGE"
  assert_summary
fi

# Index the blocks by kind.
XR_FILE=""; PUSH_FILE=""; ES_FILE=""
parse_failures=""
for f in "$WORK"/block-*.yaml; do
  kind=$(yq eval '.kind // ""' "$f" 2>/dev/null) || { parse_failures="$parse_failures $f"; continue; }
  case "$kind" in
    XDatabase)      XR_FILE="$f" ;;
    PushSecret)     PUSH_FILE="$f" ;;
    ExternalSecret) ES_FILE="$f" ;;
  esac
done

if [ -z "$parse_failures" ]; then
  _pass "every_yaml_block_parses"
else
  _fail "every_yaml_block_parses" "yq could not parse:$parse_failures"
fi

for pair in "XDatabase:$XR_FILE" "PushSecret:$PUSH_FILE" "ExternalSecret:$ES_FILE"; do
  k="${pair%%:*}"; v="${pair#*:}"
  if [ -n "$v" ]; then _pass "page_gives_a_${k}_manifest"; else _fail "page_gives_a_${k}_manifest" "no $k block on the page"; fi
done
[ -n "$XR_FILE" ] && [ -n "$PUSH_FILE" ] && [ -n "$ES_FILE" ] || assert_summary

# ---------------------------------------------------------------------------
# 1. The XDatabase matches the committed XRD
# ---------------------------------------------------------------------------
echo "── the XDatabase matches the XRD ──"
xrd_group=$(yq eval '.spec.group' "$XRD")
xrd_version=$(yq eval '.spec.versions[0].name' "$XRD")
xrd_kind=$(yq eval '.spec.names.kind' "$XRD")
assert_eq "xr_apiVersion_matches_xrd" "$xrd_group/$xrd_version" "$(yq eval '.apiVersion' "$XR_FILE")"
assert_eq "xr_kind_matches_xrd"       "$xrd_kind"               "$(yq eval '.kind' "$XR_FILE")"

xrd_props=$(yq eval '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties | keys | .[]' "$XRD" | sort)
page_fields=$(yq eval '.spec | keys | .[]' "$XR_FILE" | sort)
unknown=""
for k in $page_fields; do
  printf '%s\n' "$xrd_props" | grep -qx "$k" || unknown="$unknown $k"
done
if [ -z "$unknown" ]; then
  _pass "xr_spec_fields_all_exist_in_the_xrd"
else
  _fail "xr_spec_fields_all_exist_in_the_xrd" "the XRD has no such field(s):$unknown"
fi

missing_required=""
for k in $(yq eval '.spec.versions[0].schema.openAPIV3Schema.properties.spec.required[]' "$XRD" 2>/dev/null); do
  printf '%s\n' "$page_fields" | grep -qx "$k" || missing_required="$missing_required $k"
done
if [ -z "$missing_required" ]; then
  _pass "xr_carries_every_required_field"
else
  _fail "xr_carries_every_required_field" "the example omits required field(s):$missing_required"
fi

# The page states the XR name IS the connection Secret name, and the PushSecret
# selects that Secret. If those two drift the push silently never fires.
assert_eq "pushsecret_selects_the_xr_name" \
  "$(yq eval '.metadata.name' "$XR_FILE")" \
  "$(yq eval '.spec.selector.secret.name' "$PUSH_FILE")"
assert_eq "pushsecret_shares_the_xr_namespace" \
  "$(yq eval '.metadata.namespace' "$XR_FILE")" \
  "$(yq eval '.metadata.namespace' "$PUSH_FILE")"

# ---------------------------------------------------------------------------
# 2. The PushSecret matches the committed Keycloak precedent
# ---------------------------------------------------------------------------
echo "── the PushSecret matches the Keycloak precedent ──"
assert_eq "push_apiVersion_matches_precedent" "$(yq eval '.apiVersion' "$KC_PUSH")" "$(yq eval '.apiVersion' "$PUSH_FILE")"
assert_eq "push_store_name_matches_precedent" \
  "$(yq eval '.spec.secretStoreRefs[0].name' "$KC_PUSH")" \
  "$(yq eval '.spec.secretStoreRefs[0].name' "$PUSH_FILE")"
assert_eq "push_store_kind_matches_precedent" \
  "$(yq eval '.spec.secretStoreRefs[0].kind' "$KC_PUSH")" \
  "$(yq eval '.spec.secretStoreRefs[0].kind' "$PUSH_FILE")"

# The connection-detail key names are the provider's, observed live; the page
# must push the same set or it pushes nothing.
assert_eq "push_secret_keys_match_precedent" \
  "$(yq eval '[.spec.data[].match.secretKey] | sort | join(",")' "$KC_PUSH")" \
  "$(yq eval '[.spec.data[].match.secretKey] | sort | join(",")' "$PUSH_FILE")"

# ---------------------------------------------------------------------------
# 3. The tenant's ExternalSecret matches the committed consumer
# ---------------------------------------------------------------------------
echo "── the tenant ExternalSecret matches the committed consumer ──"
assert_eq "es_apiVersion_matches_consumer" "$(yq eval '.apiVersion' "$KC_PULL")" "$(yq eval '.apiVersion' "$ES_FILE")"
assert_eq "es_store_kind_matches_consumer" \
  "$(yq eval '.spec.secretStoreRef.kind' "$KC_PULL")" \
  "$(yq eval '.spec.secretStoreRef.kind' "$ES_FILE")"
assert_eq "es_store_name_matches_consumer" \
  "$(yq eval '.spec.secretStoreRef.name' "$KC_PULL")" \
  "$(yq eval '.spec.secretStoreRef.name' "$ES_FILE")"

# The three ESO-CRD-defaulted enums must be spelled out on every source ref, or
# the tenant's Application sits permanently OutOfSync (the #255 bug class that
# tests/unit/test_externalsecret_antidrift_enums.sh enforces for committed
# manifests — that lint scans platform-services/ and argocd/, never docs).
assert_eq "es_pins_conversionStrategy_on_every_ref" "0" \
  "$(yq eval '[.spec.data[] | select(.remoteRef.conversionStrategy == null)] | length' "$ES_FILE")"
assert_eq "es_pins_decodingStrategy_on_every_ref" "0" \
  "$(yq eval '[.spec.data[] | select(.remoteRef.decodingStrategy == null)] | length' "$ES_FILE")"
assert_eq "es_pins_metadataPolicy_on_every_ref" "0" \
  "$(yq eval '[.spec.data[] | select(.remoteRef.metadataPolicy == null)] | length' "$ES_FILE")"

# ---------------------------------------------------------------------------
# 4. The two halves address the same Secrets Manager path
# ---------------------------------------------------------------------------
echo "── the admin half and the tenant half agree ──"
push_keys=$(yq eval '[.spec.data[].match.remoteRef.remoteKey] | unique | join(",")' "$PUSH_FILE")
es_keys=$(yq eval '[.spec.data[].remoteRef.key] | unique | join(",")' "$ES_FILE")
assert_eq "push_and_pull_use_the_same_asm_key" "$push_keys" "$es_keys"

push_props=$(yq eval '[.spec.data[].match.remoteRef.property] | sort | join(",")' "$PUSH_FILE")
es_props=$(yq eval '[.spec.data[].remoteRef.property] | sort | join(",")' "$ES_FILE")
assert_eq "push_and_pull_move_the_same_properties" "$push_props" "$es_props"

# Only the k8-platform/ prefix is load-bearing: both IAM grants are scoped to
# it (terraform/management/irsa.tf). A key outside it cannot be written or read.
offenders=""
for k in $(printf '%s,%s' "$push_keys" "$es_keys" | tr ',' ' '); do
  case "$k" in
    k8-platform/*|'') ;;
    *) offenders="$offenders $k" ;;
  esac
done
if [ -z "$offenders" ]; then
  _pass "asm_keys_sit_under_the_granted_prefix"
else
  _fail "asm_keys_sit_under_the_granted_prefix" "outside k8-platform/:$offenders"
fi

assert_summary
