#!/usr/bin/env bash
# Prints the release branch (release-X.Y) whose head is <sha>, for the Release workflow: when main
# moves to a release branch and CI passes there, it releases X.Y.0 by itself. With several at <sha>,
# the oldest version: a release branch just cut from it has nothing of its own yet. Prints nothing
# when no release branch is at <sha>, or when that vX.Y.0 is out already, so CI finishing on main for
# anything else (a refactor, a test, a fix for the version that's out) releases nothing.
set -euo pipefail

sha=${1:?usage: which-release.sh <sha> [remote]}
remote=${2:-origin}

branch=$(git ls-remote --heads "$remote" 'release-*' \
    | awk -v sha="$sha" '$1 == sha && $2 ~ /^refs\/heads\/release-[0-9]+\.[0-9]+$/ { sub("^refs/heads/", "", $2); print $2 }' \
    | sort -V | head -n 1)
[[ -n $branch ]] || exit 0
if [[ -n $(git ls-remote --tags "$remote" "refs/tags/v${branch#release-}.0") ]]; then
    exit 0
fi
echo "$branch"
