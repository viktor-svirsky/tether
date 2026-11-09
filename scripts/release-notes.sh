#!/usr/bin/env bash
# Prints the list of changes for the Release workflow's notes: the issues that the commits since
# <previous> fix, one line each with its number, in issue order, and "Fixed: " before a bug's title.
# No <previous> means the first release.
#
# An issue counts when a commit says "Fixes #N" (or closes, resolves) and GitHub has it closed as done.
# Left out:
#   - an issue still open: work taken out of the release again, like #95 and #63 in 1.8 (#110)
#   - a commit that a later one reverts ("This reverts commit <sha>."), unless that revert is reverted
#   - a commit by Dependabot
#   - an issue labelled tests, ci, dependencies or documentation: nothing changed in the app
#   - a pull request, and an issue closed as not planned
# Reads the issues with gh, for GITHUB_REPOSITORY, and fails when it can't.
set -euo pipefail

previous=${1-}
repo=${GITHUB_REPOSITORY:?release-notes.sh needs GITHUB_REPOSITORY}
range=${previous:+$previous..}HEAD

# Newest first, so a revert that is itself reverted later is skipped before it can skip its commit.
reverted=$'\n'
numbers=
for sha in $(git rev-list "$range"); do
    [[ $reverted != *$'\n'$sha$'\n'* ]] || continue
    # Dependabot's commits quote the upstream release notes, whose issue numbers aren't Tether's.
    [[ $(git log -1 --format=%an "$sha") != 'dependabot[bot]' ]] || continue
    body=$(git log -1 --format=%B "$sha")
    reverted+=$(sed -nE 's/^This reverts commit ([0-9a-f]{40})\..*/\1/p' <<< "$body")$'\n'
    # grep finding nothing exits 1, which is fine. Anything else is an error.
    found=$(grep -oiE '(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' <<< "$body") || [[ $? == 1 ]]
    numbers+=${found:+$(sed -E 's/.*#//' <<< "$found")$'\n'}
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
