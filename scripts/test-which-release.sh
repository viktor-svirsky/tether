#!/usr/bin/env bash
# Tests which-release.sh against a throwaway bare repo standing in for GitHub. It decides whether CI
# finishing on main releases anything, so a wrong answer either publishes a release nobody asked for
# or never publishes one.
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/which-release.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q --bare "$tmp/remote.git"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git remote add origin "$tmp/remote.git"
commit() { git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; git rev-parse HEAD; }

fail() { echo "which-release.sh $*" >&2; exit 1; }
# says <stdout> <sha>: it succeeds, prints <stdout> and nothing on stderr.
says() {
    local want=$1 sha=$2 status=0
    "$script" "$sha" > "$tmp/out" 2> "$tmp/err" || status=$?
    local out err
    out=$(< "$tmp/out") err=$(< "$tmp/err")
    [[ $status == 0 && $out == "$want" && -z $err ]] \
        || fail "$sha: want exit 0 and '$want', got exit $status, stdout '$out', stderr '$err'"
}

one=$(commit one)
git push -q origin main
says "" "$one" # main on its own: a refactor, a test, CI

git push -q origin "$one:refs/heads/release-1.6"
says "release-1.6" "$one"

two=$(commit two)
git push -q origin main
says "" "$two" # main moved past the release branch: a fix for the shipped version is released by hand

# Only a release-X.Y branch counts.
git push -q origin "$two:refs/heads/release-notes" "$two:refs/heads/release-1.7-beta"
says "" "$two"

# Two release branches at one commit: the older version. A release branch cut from the one main is at
# has nothing of its own yet.
git push -q origin "$two:refs/heads/release-1.10" "$two:refs/heads/release-1.9"
says "release-1.9" "$two"

# Out already: CI running again on main releases nothing twice, and not the next one either.
git tag v1.9.0 "$two"
git push -q origin v1.9.0
says "" "$two"
says "release-1.6" "$one" # a tag on another commit doesn't count

status=0
"$script" > /dev/null 2>&1 || status=$?
[[ $status != 0 ]] || fail "with no sha: want a failure"
echo "which-release.sh: all passed"
