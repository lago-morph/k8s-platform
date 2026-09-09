#!/usr/bin/env bash
# beads-sync.sh — drive beads (bd) against a Dolt-in-git remote that lives on a
# BRANCH ref instead of the default refs/dolt/data.
#
# Subcommands: install | bootstrap | push | status
#
# Env:
#   BD_VERSION       pinned bd version for `install` (default 1.2.2)
#   BEADS_DATA_REF   git ref holding the Dolt data (default refs/heads/beads-dolt-data)
set -uo pipefail

BD_VERSION="${BD_VERSION:-1.2.2}"
BEADS_DATA_REF="${BEADS_DATA_REF:-refs/heads/beads-dolt-data}"

die() {
    printf 'beads-sync: %s\n' "$1" >&2
    exit 1
}

repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

db_name() {
    sed -n 's/.*"dolt_database"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$1/.beads/metadata.json" 2>/dev/null | head -n 1
}

# Dolt only treats URLs ending in .git as Git remotes; the sandbox's origin
# URL has no suffix, so normalise here.
origin_url() {
    u=$(git config --get remote.origin.url) || return 1
    case "$u" in
        *.git) printf '%s\n' "$u" ;;
        *) printf '%s.git\n' "$u" ;;
    esac
}

remote_data_sha() {
    git ls-remote origin "$BEADS_DATA_REF" 2>/dev/null | cut -f1 | head -n 1
}

# Rewrite the Dolt remote in repo_state.json so pushes/pulls use the branch ref.
set_data_ref() {
    state="$1/.beads/embeddeddolt/$2/.dolt/repo_state.json"
    [ -f "$state" ] || die "no Dolt repo state at $state"
    command -v python3 >/dev/null 2>&1 || die "python3 is required to set the Dolt data ref"
    python3 - "$state" "git+$3" "$BEADS_DATA_REF" <<'PY'
import json, sys
path, url, ref = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    state = json.load(fh)
state.setdefault("remotes", {})["origin"] = {
    "name": "origin",
    "url": url,
    "fetch_specs": ["refs/heads/*:refs/remotes/origin/*"],
    "params": {"git_ref": ref},
}
with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
PY
}

unpushed() {
    out=$(bd diff origin/main main 2>&1)
    case "$out" in
        *"No changes between"*) return 1 ;;
        *) return 0 ;;
    esac
}

cmd_install() {
    have=""
    if command -v bd >/dev/null 2>&1; then
        have=$(bd version 2>/dev/null | sed -n 's/^bd version \([0-9][^ ]*\).*/\1/p')
    fi
    if [ "$have" = "$BD_VERSION" ]; then
        printf 'bd %s already installed\n' "$BD_VERSION"
        return 0
    fi
    printf 'installing @beads/bd@%s (found: %s)\n' "$BD_VERSION" "${have:-none}"
    npm install -g "@beads/bd@$BD_VERSION" >/dev/null 2>&1 ||
        die "npm install -g @beads/bd@$BD_VERSION failed"
    bd version || die "bd not runnable after install"
}

# Clone the Dolt database out of the branch ref via a throwaway local bare repo
# whose copy of the data sits on refs/dolt/data, which is what bd/dolt expect.
bootstrap_from_ref() {
    root="$1"
    db="$2"
    url="$3"
    mirror="${TMPDIR:-/tmp}/beads-sync-mirror.$$.git"
    rm -rf "$mirror"
    git fetch -q origin "+$BEADS_DATA_REF:refs/beads-sync/data" ||
        die "cannot fetch $BEADS_DATA_REF from origin"
    git init -q --bare "$mirror" || die "cannot create mirror $mirror"
    git push -q "$mirror" refs/beads-sync/data:refs/dolt/data >/dev/null 2>&1 ||
        die "cannot seed mirror with Dolt data"
    git push -q "$mirror" HEAD:refs/heads/main >/dev/null 2>&1 ||
        die "cannot seed mirror with a branch"

    cp "$root/.beads/config.yaml" "$root/.beads/config.yaml.beads-sync-bak" ||
        die "cannot back up config.yaml"
    sed -i "s|^sync.remote:.*|sync.remote: \"git+file://$mirror\"|" "$root/.beads/config.yaml"
    bd bootstrap --yes
    rc=$?
    mv "$root/.beads/config.yaml.beads-sync-bak" "$root/.beads/config.yaml"
    rm -rf "$mirror"
    git update-ref -d refs/beads-sync/data
    [ "$rc" -eq 0 ] || die "bd bootstrap from mirror failed (rc=$rc)"
    set_data_ref "$root" "$db" "$url"
}

cmd_bootstrap() {
    root=$(repo_root) || die "not inside a git repository"
    [ -n "$root" ] || die "not inside a git repository"
    cd "$root" || die "cannot cd to $root"
    db=$(db_name "$root")
    [ -n "$db" ] || die "no .beads/metadata.json — run bd init first"
    url=$(origin_url) || die "no git remote origin"
    sha=$(remote_data_sha)
    # bd warns on every command when .beads is group/world readable; a fresh
    # git clone creates it 0755.
    chmod 700 "$root/.beads" 2>/dev/null || true

    if [ -d "$root/.beads/embeddeddolt/$db/.dolt" ]; then
        if [ -z "$sha" ]; then
            printf 'local database present, remote %s has no data yet — nothing to pull\n' \
                "$BEADS_DATA_REF"
            return 0
        fi
        set_data_ref "$root" "$db" "$url"
        bd dolt pull || die "bd dolt pull failed"
        return 0
    fi

    if [ -n "$sha" ]; then
        printf 'cloning Dolt data from %s (%s)\n' "$BEADS_DATA_REF" "$sha"
        bootstrap_from_ref "$root" "$db" "$url"
    else
        printf 'no Dolt data on %s — creating a fresh local database\n' "$BEADS_DATA_REF"
        bd init --prefix "$db" --skip-agents --skip-hooks --non-interactive \
            --role maintainer --init-if-missing || die "bd init failed"
        set_data_ref "$root" "$db" "$url"
    fi
    bd list >/dev/null 2>&1 || die "database unusable after bootstrap"
    printf 'bootstrap complete\n'
}

cmd_push() {
    root=$(repo_root) || die "not inside a git repository"
    cd "$root" || die "cannot cd to $root"
    db=$(db_name "$root")
    [ -n "$db" ] || die "no .beads/metadata.json — run bootstrap first"
    url=$(origin_url) || die "no git remote origin"
    set_data_ref "$root" "$db" "$url"
    if ! unpushed; then
        printf 'nothing to push\n'
        return 0
    fi
    if ! bd dolt push; then
        # Another clone pushed first. Different beads merge cleanly on pull;
        # the same bead edited in two clones does not (ai/beads-dolt-git-remotes.md §4).
        printf 'push rejected; pulling and retrying once\n' >&2
        bd dolt pull || die "bd dolt pull failed after a rejected push — same-bead conflict? see ai/beads-dolt-git-remotes.md §4"
        bd dolt push || die "bd dolt push failed after pull — resolve by hand (ai/beads-dolt-git-remotes.md §4)"
    fi
    printf 'pushed to %s\n' "$BEADS_DATA_REF"
}

cmd_status() {
    root=$(repo_root) || die "not inside a git repository"
    cd "$root" || die "cannot cd to $root"
    json=$(bd status --json 2>/dev/null)
    ready=$(printf '%s' "$json" | sed -n 's/.*"ready_issues"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
    prog=$(printf '%s' "$json" | sed -n 's/.*"in_progress_issues"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
    if unpushed; then
        un="yes"
    else
        un="no"
    fi
    printf 'beads: ready=%s in_progress=%s unpushed=%s\n' "${ready:-?}" "${prog:-?}" "$un"
}

case "${1:-}" in
    install) cmd_install ;;
    bootstrap) cmd_bootstrap ;;
    push) cmd_push ;;
    status) cmd_status ;;
    *)
        printf 'usage: %s {install|bootstrap|push|status}\n' "$0" >&2
        exit 2
        ;;
esac
