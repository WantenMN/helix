#!/bin/bash
set -e

echo "==> Fetching upstream..."
git fetch https://github.com/helix-editor/helix.git master

LOCAL=$(git rev-parse master 2>/dev/null || echo "none")
UPSTREAM=$(git rev-parse FETCH_HEAD)

if [ "$LOCAL" = "$UPSTREAM" ]; then
    echo "Already up to date. Nothing to do."
    exit 0
fi

echo "==> Upstream has new commits. Merging..."

# Update local master
git checkout master
git merge --ff-only FETCH_HEAD

# Merge into release branch
git checkout release
git merge master --no-edit -m "ci: merge upstream/master"

# Generate tag: YY.MM.DD, with incrementing suffix for same day
PREFIX=$(date +%y.%m.%d)
LATEST=$(git tag -l "${PREFIX}*" --sort=-version:refname | head -1)
if [ -z "$LATEST" ]; then
    TAG=$PREFIX
elif [ "$LATEST" = "$PREFIX" ]; then
    TAG="${PREFIX}.1"
else
    LAST_NUM=${LATEST##*.}
    TAG="${PREFIX}.$((LAST_NUM + 1))"
fi

echo "==> Creating tag: $TAG"
git tag -a "$TAG" -m "Release $TAG"

echo ""
echo "Done! Tag '$TAG' created on release branch."
echo "Run the following to publish:"
echo "  git push origin master release $TAG"
