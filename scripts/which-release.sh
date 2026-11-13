#!/usr/bin/env bash
# Prints the release branch (release-X.Y) that main moved up to at <sha>, for the Release workflow:
# when main moves to a release branch and CI passes there, it releases X.Y.0 by itself.
#
# The release branch has to have got to <sha> before main did, by GitHub's push history. When main got
# there first, the release branch has nothing of its own: it was cut from main, or fast-forwarded to a
# fix on main, which is how 1.9.0 went out with nothing new (#120). Pushed in the same second, it can't
# tell, so it releases nothing. With several at <sha>, the oldest version: a release branch just cut
# from another has nothing of its own yet. Prints nothing when no release branch is at <sha>, or when
# that vX.Y.0 is out already, so CI finishing on main for anything else (a refactor, a test, a fix for
# the version that's out) releases nothing.
#
# Reads the push history with gh, for GITHUB_REPOSITORY, and fails when it can't.
set -euo pipefail

sha=${1:?usage: which-release.sh <sha> [remote]}
remote=${2:-origin}
repo=${GITHUB_REPOSITORY:?which-release.sh needs GITHUB_REPOSITORY}

# reached <branch>: when <branch> first got to <sha> on GitHub, as an ISO 8601 UTC time, or nothing.
reached() {
    local pushes
    # A command substitution doesn't stop on errors, so return gh's failure to the caller, which does.
    pushes=$(gh api --paginate "repos/$repo/activity?ref=refs/heads/$1&per_page=100") || return
    jq -rs --arg sha "$sha" '[.[][] | select(.after == $sha) | .timestamp] | min // empty' <<< "$pushes"
}

branches=$(git ls-remote --heads "$remote" 'release-*' \
    | awk -v sha="$sha" '$1 == sha && $2 ~ /^refs\/heads\/release-[0-9]+\.[0-9]+$/ { sub("^refs/heads/", "", $2); print $2 }' \
    | sort -V)
[[ -n $branches ]] || exit 0
main=$(reached main)
[[ -n $main ]] || exit 0
branch=
for candidate in $branches; do
    at=$(reached "$candidate")
    # The same format, so the strings sort as the times do.
    if [[ -n $at && $at < $main ]]; then
        branch=$candidate
        break
    fi
done
if [[ -z $branch ]]; then
    # On stderr, for the log: the workflow reads stdout as the answer.
    echo "Main got to $sha before ${branches//$'\n'/, } or with it: nothing of its own to release." >&2
    exit 0
fi
if [[ -n $(git ls-remote --tags "$remote" "refs/tags/v${branch#release-}.0") ]]; then
    exit 0
fi
echo "$branch"
