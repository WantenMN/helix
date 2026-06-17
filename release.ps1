Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "==> Fetching upstream..."
git fetch https://github.com/helix-editor/helix.git master

$local = git rev-parse master 2>$null
$upstream = git rev-parse FETCH_HEAD

if ($local -eq $upstream) {
    Write-Host "Already up to date. Nothing to do."
    exit 0
}

Write-Host "==> Upstream has new commits. Merging..."

# Update local master
git checkout master
git merge --ff-only FETCH_HEAD

# Merge into release branch
git checkout release
git merge master --no-edit -m "ci: merge upstream/master"

# Generate tag: YY.MM.DD, with incrementing suffix for same day
$prefix = Get-Date -Format "yy.MM.dd"
$latest = (git tag -l "${prefix}*" --sort=-version:refname | Select-Object -First 1)

if (-not $latest) {
    $tag = $prefix
} elseif ($latest -eq $prefix) {
    $tag = "${prefix}.1"
} else {
    $lastNum = $latest.Split(".")[-1]
    $tag = "${prefix}.$([int]$lastNum + 1)"
}

Write-Host "==> Creating tag: $tag"
git tag -a $tag -m "Release $tag"

Write-Host ""
Write-Host "Done! Tag '$tag' created on release branch."
Write-Host "Run the following to publish:"
Write-Host "  git push origin master release $tag"
