#!/usr/bin/env bash
# Tests which-release.sh against a throwaway bare repo standing in for GitHub, and a stand-in gh that
# answers GitHub's push history from what this test pushed. It decides whether CI finishing on main
# releases anything, so a wrong answer either publishes a release nobody asked for or never publishes one.
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/which-release.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q --bare "$tmp/remote.git"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git remote add origin "$tmp/remote.git"
commit() { git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; git rev-parse HEAD; }

# The stand-in gh: `gh api --paginate repos/<repo>/activity?ref=refs/heads/<branch>&per_page=100` prints
# that branch's pushes, kept one JSON object a line in $tmp/activity/<branch>. Anything else fails.
export GITHUB_REPOSITORY=someone/tether ACTIVITY=$tmp/activity
mkdir "$tmp/bin" "$ACTIVITY"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -e $ACTIVITY/down ]] || { echo "gh: GitHub is down" >&2; exit 1; }
[[ $1 == api && $2 == --paginate && $3 =~ ^repos/$GITHUB_REPOSITORY/activity\?ref=refs/heads/([^&]+)\&per_page=100$ ]] \
    || { echo "gh: unexpected call: $*" >&2; exit 1; }
file=$ACTIVITY/${BASH_REMATCH[1]}
if [[ -f $file ]]; then jq -s . "$file"; else echo '[]'; fi
EOF
chmod +x "$tmp/bin/gh"
export PATH=$tmp/bin:$PATH

# push <sha> <branch>...: pushes <sha> to each branch, one push after another, and records each the
# way GitHub does. push_together pushes them all in the same second.
pushes=0
record() {
    printf '{"after":"%s","timestamp":"2026-11-08T10:%02d:%02dZ"}\n' "$1" $((pushes / 60)) $((pushes % 60)) \
        >> "$ACTIVITY/$2"
}
push() {
    local sha=$1 branch
    shift
    for branch in "$@"; do
        pushes=$((pushes + 1))
        git push -q -f origin "$sha:refs/heads/$branch"
        record "$sha" "$branch"
    done
}
push_together() {
    local sha=$1 branch
    shift
    pushes=$((pushes + 1))
    for branch in "$@"; do
        git push -q -f origin "$sha:refs/heads/$branch"
        record "$sha" "$branch"
    done
}

fail() { echo "which-release.sh $*" >&2; exit 1; }
# says <stdout> <sha> [<stderr>]: it succeeds, prints <stdout>, and <stderr> or nothing on stderr.
says() {
    local want=$1 sha=$2 want_err=${3-} status=0
    "$script" "$sha" > "$tmp/out" 2> "$tmp/err" || status=$?
    local out err
    out=$(< "$tmp/out") err=$(< "$tmp/err")
    [[ $status == 0 && $out == "$want" && $err == "$want_err" ]] \
        || fail "$sha: want exit 0, '$want' and '$want_err' on stderr, got exit $status, stdout '$out', stderr '$err'"
}

one=$(commit one)
push "$one" main
says "" "$one" # main on its own: a refactor, a test, CI

# A release branch cut from main has nothing of its own yet.
push "$one" release-1.6
says "" "$one" "Main got to $one before release-1.6 or with it: nothing of its own to release."

two=$(commit two)
push "$two" release-1.6
says "" "$two" # a feature on the release branch, and main isn't there yet
push "$two" main
says "release-1.6" "$two" # main moved up to the release branch

git tag v1.6.0 "$two"
git push -q origin v1.6.0
says "" "$two" # out already: CI running again on main releases nothing twice

# How 1.9.0 went out empty (#120): a fix lands on main, and the next release branch is fast-forwarded
# to it. Main got there first, so the release branch has nothing of its own.
push "$two" release-1.7
three=$(commit three)
push "$three" main release-1.7
says "" "$three" "Main got to $three before release-1.7 or with it: nothing of its own to release."
# Once the release branch has something of its own, main moving up to it releases it.
four=$(commit four)
push "$four" release-1.7
says "" "$four" # main isn't there yet
push "$four" main
says "release-1.7" "$four"

# Only a release-X.Y branch counts.
six=$(commit six)
push "$six" release-notes release-1.7-beta main
says "" "$six"

# Two release branches at one commit before main: the older version. Release-1.9 was cut from
# release-1.8 before main moved, and has nothing of its own yet.
seven=$(commit seven)
push "$seven" release-1.8 release-1.9 main
says "release-1.8" "$seven"
# A release branch pushed in the same second as main can't tell which came first: it releases nothing.
eight=$(commit eight)
push_together "$eight" release-1.10 main
says "" "$eight" "Main got to $eight before release-1.10 or with it: nothing of its own to release."

# Out already: CI running again on main releases nothing twice, and not the next one either.
git tag v1.8.0 "$seven"
git push -q origin v1.8.0
says "" "$seven"
says "release-1.7" "$four" # a tag on another commit doesn't count

# No answer from GitHub fails the run instead of releasing or skipping without a word.
touch "$ACTIVITY/down"
status=0
"$script" "$four" > /dev/null 2>&1 || status=$?
[[ $status != 0 ]] || fail "with GitHub down: want a failure"
rm "$ACTIVITY/down"

status=0
"$script" > /dev/null 2>&1 || status=$?
[[ $status != 0 ]] || fail "with no sha: want a failure"
echo "which-release.sh: all passed"
