#!/usr/bin/env bash
# Prints the list of changes for the Release workflow's notes: the issues that the commits since
# <previous> fix, one line each with its number, in issue order, and "Fixed: " before a bug's title.
# No <previous> means the first release.
#
# An issue counts when a commit has a line starting "Fixes #N" (or closes, resolves) and GitHub has it
# closed as completed. The issue's state decides, not the commits: work taken out of a release reopens
# its issue, which keeps it out, like #95 and #63 in 1.8 (#110). Work put back needs its own Fixes line.
# Left out:
#   - a revert: its subject quotes the reverted commit's "Fixes #N"
#   - a commit by Dependabot: it quotes upstream notes, whose issue numbers aren't Tether's
#   - an issue labelled tests, ci, dependencies or documentation: nothing changed in the app
#   - a pull request, and an issue closed any other way than completed
# With --require-change, nothing to list fails with exit 3 instead, for the Release workflow: a release
# nobody using the app can tell apart from the last one isn't published (#139).
# Reads the issues with gh, for GITHUB_REPOSITORY, and fails when it can't.
set -euo pipefail

previous= require=
for arg in "$@"; do
    case $arg in
        --require-change) require=1 ;;
        -*) echo "usage: release-notes.sh [<previous>] [--require-change]" >&2; exit 2 ;;
        *) [[ -z $previous ]] || { echo "usage: release-notes.sh [<previous>] [--require-change]" >&2; exit 2; }
           previous=$arg ;;
    esac
done
repo=${GITHUB_REPOSITORY:?release-notes.sh needs GITHUB_REPOSITORY}
range=${previous:+$previous..}HEAD

keyword='(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+'
numbers=
# On its own line, so a range git can't read stops the run: a failure inside the for list wouldn't.
shas=$(git rev-list "$range")
for sha in $shas; do
    [[ $(git log -1 --format=%an "$sha") != 'dependabot[bot]' ]] || continue
    body=$(git log -1 --format=%B "$sha")
    [[ $body != *"This reverts commit "* ]] || continue
    # Only lines that start with the keyword ("Fixes #5, fixes #6"), so prose quoting one doesn't count.
    # grep finding nothing exits 1, which is fine. Anything else is an error.
    lines=$(grep -iE "^[[:space:]]*$keyword" <<< "$body") || [[ $? == 1 ]]
    [[ -n $lines ]] || continue
    found=$(grep -oiE "(^|[^[:alnum:]_])$keyword" <<< "$lines")
    numbers+=$(sed -E 's/.*#//' <<< "$found")$'\n'
done

numbers=$(sort -nu <<< "$numbers")
lines=
for n in $numbers; do
    json=$(gh api "repos/$repo/issues/$n")
    line=$(jq -r '
        select(.pull_request == null and .state == "closed" and .state_reason == "completed")
        | select([.labels[].name] | any(IN("tests", "ci", "dependencies", "documentation")) | not)
        | "- \(if any(.labels[]; .name == "bug") then "Fixed: " else "" end)\(.title) (#\(.number))"' <<< "$json")
    lines+=${line:+$line$'\n'}
done
if [[ -n $lines ]]; then
    printf '%s' "$lines"
elif [[ -n $require ]]; then
    echo "Nothing since ${previous:-the start} that people using the app would see: no release." >&2
    exit 3
else
    echo "- No change you'd see in the app."
fi
