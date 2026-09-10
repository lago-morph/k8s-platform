#!/usr/bin/env bash
# refresh.sh — pull a newer checkout onto the ops box.
#
# The box clones this repository at boot. When the scripts change, run this
# rather than rebuilding the instance.
#
#   refresh.sh              pull the current branch
#   refresh.sh <ref>        switch to a branch or tag and pull it
set -euo pipefail
ROOT="${K8_PLATFORM_ROOT:-/opt/k8-platform}"
REF="${1:-}"

[ -d "$ROOT/.git" ] || { echo "no checkout at $ROOT" >&2; exit 1; }

git -C "$ROOT" fetch --all --prune
if [ -n "$REF" ]; then
  git -C "$ROOT" checkout "$REF"
fi
git -C "$ROOT" pull --ff-only

echo "now at: $(git -C "$ROOT" rev-parse --short HEAD) on $(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"

# Tool versions are pinned in versions.env; re-run the installer in case they
# moved with the checkout.
bash "$ROOT/scripts/sandbox-setup.sh"
