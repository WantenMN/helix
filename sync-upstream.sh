#!/usr/bin/env bash
# Sync release_fork with upstream master and refresh grammars.lock.json if needed.
# It NEVER pushes: review the result, commit the lock (if updated), push manually.
#
# Usage: ./sync-upstream.sh [-j N]
set -euo pipefail

UPSTREAM_URL="https://github.com/helix-editor/helix.git"
BRANCH="release_fork"
JOBS=8
for i in "$@"; do :; done
if [[ "${1:-}" == "-j" ]]; then JOBS="${2:?}"; fi

die() { echo "sync-upstream: $*" >&2; exit 1; }

# --- 0. sanity ---------------------------------------------------------------
[[ "$(git branch --show-current)" == "$BRANCH" ]] || die "not on $BRANCH, abort"
[[ -z "$(git status --porcelain)" ]] || die "worktree dirty, commit or stash first"

# --- 1. upstream -------------------------------------------------------------
git remote get-url upstream >/dev/null 2>&1 \
  || { echo "adding upstream remote"; git remote add upstream "$UPSTREAM_URL"; }
git fetch upstream

if git merge-base --is-ancestor upstream/master HEAD; then
  echo "already up to date with upstream/master"
else
  echo "== new upstream commits =="
  git log --oneline "HEAD..upstream/master"
fi
old_base="$(git merge-base HEAD upstream/master)"

# --- 2. rebase ----------------------------------------------------------------
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse upstream/master)" ]]; then
  echo "== rebasing $BRANCH onto upstream/master =="
  if ! git rebase upstream/master; then
    echo "conflict during rebase, aborting (your branch is untouched)" >&2
    git rebase --abort
    exit 1
  fi
else
  echo "branch already on upstream/master tip, no rebase needed"
fi

# --- 3. grammars lock ----------------------------------------------------------
if git diff "$old_base" HEAD -- languages.toml | grep -q .; then
  echo "== languages.toml changed upstream =="
  git diff --stat "$old_base" HEAD -- languages.toml
else
  echo "languages.toml untouched by rebase"
fi

echo "== checking grammars.lock.json =="
if nix run nixpkgs#python3 -- ./update-grammars.py --check; then
  echo "lock up to date, nothing to do"
else
  echo "== lock stale, refreshing (only missing/stale repos are fetched) =="
  nix run nixpkgs#python3 -- ./update-grammars.py -j "$JOBS"
  nix run nixpkgs#python3 -- ./update-grammars.py --check
  git add grammars.lock.json
  echo "lock refreshed and staged"
fi

# --- 4. summary -----------------------------------------------------------------
echo
echo "== result =="
git log --oneline -3
git status --short
echo
echo "next (manual): review, commit anything staged, then push:"
echo "  git push --force-with-lease origin $BRANCH"
echo "then in dotfiles/nixos: nix flake update helix && rebuild"
