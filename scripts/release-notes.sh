#!/usr/bin/env bash
# Prints the list of changes for the Release workflow's notes: the issues that the commits since
# <previous> fix, one line each with its number, in issue order, and "Fixed: " before a bug's title.
# No <previous> means the first release.
#
# An issue counts when a commit has a line starting "Fixes #N" (or closes, resolves) and GitHub has it
# closed as done.
# Left out:
#   - an issue still open: work taken out of the release again, like #95 and #63 in 1.8 (#110)
#   - a commit that a later one reverts, unless that revert is reverted, and for a merge every commit
#     it brought in. A revert itself fixes nothing, though its subject quotes "Fixes #N". A revert of
#     a revert from before <previous> puts that fix back in, even though the fix is before <previous>.
#   - a commit by Dependabot
#   - an issue labelled tests, ci, dependencies or documentation: nothing changed in the app
#   - a pull request, and an issue closed as not planned
# Reads the issues with gh, for GITHUB_REPOSITORY, and fails when it can't.
set -euo pipefail

previous=${1-}
repo=${GITHUB_REPOSITORY:?release-notes.sh needs GITHUB_REPOSITORY}
range=${previous:+$previous..}HEAD

# The helpers set globals instead of printing, since a command substitution doesn't stop on errors.

# reverts_of <body>: sets pairs to a "<commit> <mainline parent>" line for each commit the body says it
# reverts. git revert writes "This reverts commit <sha>.", and for a merge "This reverts commit <merge>,
# reversing\nchanges made to <mainline parent>.", which takes out every commit the merge brought in.
reverts_of() {
    local found
    # grep finding nothing exits 1, which is fine. Anything else is an error.
    found=$(tr '\n' ' ' <<< "$1" \
        | grep -oE 'This reverts commit [0-9a-f]{40}(\.|, reversing changes made to [0-9a-f]{40}\.)') || [[ $? == 1 ]]
    pairs=
    [[ -z $found ]] \
        || pairs=$(sed -E 's/This reverts commit ([0-9a-f]{40})(, reversing changes made to ([0-9a-f]{40}))?\./\1 \3/' <<< "$found")
}

# commits_of <commit> <mainline parent>: sets commits to what a revert of <commit> takes out: the
# commit, or for a merge every commit it brought in.
commits_of() {
    if [[ -n $2 ]]; then
        commits=$(git rev-list "$2..$1")
    else
        commits=$1
    fi
}

# collect <body>: adds the issues the body says it fixes to numbers, from lines that start with the
# keyword ("Fixes #5, fixes #6"), so prose quoting one doesn't count.
collect() {
    local keyword='(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' lines found=
    lines=$(grep -iE "^[[:space:]]*$keyword" <<< "$1") || [[ $? == 1 ]]
    [[ -z $lines ]] || found=$(grep -oiE "(^|[^[:alnum:]_])$keyword" <<< "$lines")
    numbers+=${found:+$(sed -E 's/.*#//' <<< "$found")$'\n'}
}

# restore <commit>: a revert in the range reverts <commit>. When <commit> is itself a revert from before
# <previous>, this puts back what it took out, which the previous release didn't have: collect it. Not
# when a revert from before <previous> had put it back already.
restore() {
    local target=$1 status=0 taken_out commit body
    [[ -n $previous ]] || return 0
    git merge-base --is-ancestor "$target" "$previous" || status=$?
    (( status != 1 )) || return 0
    (( status == 0 )) || return "$status"
    [[ $previous_log != *"This reverts commit $target"* ]] || return 0
    reverts_of "$(git log -1 --format=%B "$target")"
    taken_out=$pairs
    while read -r commit parent; do
        [[ -n $commit ]] || continue
        commits_of "$commit" "$parent"
        for commit in $commits; do
            body=$(git log -1 --format=%B "$commit")
            reverts_of "$body"
            [[ -n $pairs ]] || collect "$body"
        done
    done <<< "$taken_out"
}

previous_log=
[[ -z $previous ]] || previous_log=$(git log --format=%B "$previous" | tr '\n' ' ')
# A revert always comes before what it reverts in --topo-order, so a revert that is itself reverted
# later is skipped before it can skip anything.
reverted=$'\n'
numbers=
for sha in $(git rev-list --topo-order "$range"); do
    [[ $reverted != *$'\n'$sha$'\n'* ]] || continue
    # Dependabot's commits quote the upstream release notes, whose issue numbers aren't Tether's.
    [[ $(git log -1 --format=%an "$sha") != 'dependabot[bot]' ]] || continue
    body=$(git log -1 --format=%B "$sha")
    reverts_of "$body"
    if [[ -n $pairs ]]; then
        while read -r target parent; do
            commits_of "$target" "$parent"
            reverted+=$commits$'\n'
            restore "$target"
        done <<< "$pairs"
        # Its subject quotes the reverted one's, "Fixes #N" and all: a revert fixes nothing itself.
        continue
    fi
    collect "$body"
done

numbers=$(sort -nu <<< "$numbers")
lines=
for n in $numbers; do
    json=$(gh api "repos/$repo/issues/$n")
    line=$(jq -r '
        select(.pull_request == null and .state == "closed" and .state_reason != "not_planned")
        | select([.labels[].name] | any(IN("tests", "ci", "dependencies", "documentation")) | not)
        | "- \(if any(.labels[]; .name == "bug") then "Fixed: " else "" end)\(.title) (#\(.number))"' <<< "$json")
    lines+=${line:+$line$'\n'}
done
if [[ -n $lines ]]; then
    printf '%s' "$lines"
else
    echo "- No change you'd see in the app."
fi
