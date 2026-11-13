#!/usr/bin/env bash
# Tests release-notes.sh in a throwaway repo, with a stand-in gh that answers issues from files this
# test writes. The notes are what people read about a release, so a wrong answer lists work they
# can't see or that was taken out again (#110), or leaves out what changed.
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/release-notes.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
g() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { g commit -q --allow-empty -m "$1"; git rev-parse HEAD; }
# change <file> <message>: a commit that changes <file>, since git revert needs a change to take out.
change() { echo "$2" >> "$1"; g add "$1"; g commit -q -m "$2"; }

# The stand-in gh: `gh api repos/<repo>/issues/<n>` prints $tmp/issues/<n>.json. Anything else fails.
export GITHUB_REPOSITORY=someone/tether ISSUES=$tmp/issues
mkdir "$tmp/bin" "$ISSUES"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && $1 == api && $2 =~ ^repos/$GITHUB_REPOSITORY/issues/([0-9]+)$ ]] \
    || { echo "gh: unexpected call: $*" >&2; exit 1; }
cat "$ISSUES/${BASH_REMATCH[1]}.json" 2> /dev/null || { echo "gh: HTTP 404: Not Found" >&2; exit 1; }
EOF
chmod +x "$tmp/bin/gh"
export PATH=$tmp/bin:$PATH

# issue <n> <state> <title> [<label>...]: what GitHub says about issue <n>.
issue() {
    local n=$1 state=$2 title=$3
    shift 3
    jq -n --argjson n "$n" --arg state "$state" --arg title "$title" '{number: $n, state: $state, title: $title,
        state_reason: (if $state == "closed" then "completed" else null end),
        labels: [$ARGS.positional[] | {name: .}]}' --args "$@" > "$ISSUES/$n.json"
}

fail() { echo "release-notes.sh $*" >&2; exit 1; }
# says <stdout> <args>: it succeeds, prints <stdout> and nothing on stderr.
says() {
    local want=$1 status=0
    shift
    "$script" "$@" > "$tmp/out" 2> "$tmp/err" || status=$?
    local out err
    out=$(< "$tmp/out") err=$(< "$tmp/err")
    [[ $status == 0 && $out == "$want" && -z $err ]] \
        || fail "$*: want exit 0 and '$want', got exit $status, stdout '$out', stderr '$err'"
}

issue 1 closed "Show where a device connects from" enhancement ios
commit "$(printf 'Show where a device connects from\n\nFixes #1')" > /dev/null
says "- Show where a device connects from (#1)" # the first release: every commit counts
git tag v1.0.0

says "- No change you'd see in the app." v1.0.0

# Each issue a commit says it fixes, once, in issue order, from a merge commit too. A bug says Fixed.
issue 5 closed "Keep sharing during a call" bug ios
issue 6 closed 'Say "Not used this month"' enhancement
issue 9 closed "Point every device's DNS at Tether" enhancement wireguard
commit "$(printf 'Keep sharing during a call\n\nFixes #6, fixes #5')" > /dev/null
commit "$(printf 'Try the sound again\n\nCloses #5')" > /dev/null
commit "$(printf 'Merge #9: point DNS at Tether\n\nResolves #9')" > /dev/null
commit "$(printf 'Name it the same everywhere\n\nPart of #6\nRefs #10')" > /dev/null
says "$(printf '%s\n' '- Fixed: Keep sharing during a call (#5)' '- Say "Not used this month" (#6)' \
    "- Point every device's DNS at Tether (#9)")" v1.0.0
git tag v1.1.0

# Left out: work nobody using the app sees, by the issue's labels.
issue 2 closed "A test races under -race" bug tests
issue 3 closed "Give the CI job 30 minutes" ci
issue 4 closed "Bump golang.org/x/net" dependencies
issue 7 closed "Say how to cover a TV through a laptop" documentation
commit "$(printf 'Wait for the log line\n\nFixes #2\nFixes #3\nFixes #4\nFixes #7')" > /dev/null
says "- No change you'd see in the app." v1.1.0

# Left out: work taken out again. Taking it out reopens its issue, and an open issue wasn't fixed.
issue 11 open "Take the router role from a paused router" bug wireguard
commit "$(printf 'Take the router role from a paused router\n\nFixes #11')" > /dev/null
# Left out: a pull request, and an issue closed as not planned.
jq -n '{number: 13, state: "closed", title: "A pull request", labels: [], pull_request: {url: "x"}}' > "$ISSUES/13.json"
jq -n '{number: 14, state: "closed", state_reason: "not_planned", title: "Not planned", labels: []}' > "$ISSUES/14.json"
commit "$(printf 'Two more\n\nFixes #13\nFixes #14')" > /dev/null
# Dependabot quotes upstream notes, whose numbers aren't this repo's: #16 doesn't exist here.
git -c user.name='dependabot[bot]' -c user.email=d@d commit -q --allow-empty \
    -m "$(printf 'Bump golang.org/x/net\n\nFixes #16 upstream')"
says "- No change you'd see in the app." v1.1.0
git tag v1.2.0

# A revert fixes nothing, though its subject quotes the reverted one's "Fixes #N".
issue 19 closed "Show config status" enhancement
change config "Fixes #19: Show config status"
git tag v1.3.0
g revert --no-edit HEAD > /dev/null
says "- No change you'd see in the app." v1.3.0
# Put back later, the change counts again only with its own Fixes line.
change config "$(printf 'Show config status again\n\nFixes #19')"
says "- Show config status (#19)" v1.3.0

# Only a line that starts with the keyword counts: prose that quotes one fixes nothing.
git tag v1.4.0
issue 21 closed "Something from long ago" bug
commit "$(printf 'Explain the notes\n\nA revert subject like "Fixes #21: ..." brought #21 back.')" > /dev/null
says "- No change you'd see in the app." v1.4.0

# --require-change stops a release that has nothing to show, like 1.9.0 (#120) or a test fix that
# reached a release branch before main (#139): it fails with nothing on stdout.
status=0
"$script" v1.4.0 --require-change > "$tmp/out" 2> "$tmp/err" || status=$?
[[ $status == 3 && ! -s $tmp/out && -s $tmp/err ]] || fail "v1.4.0 --require-change: want exit 3, an error and no notes, got exit $status"
issue 23 closed "Keep the code on screen" enhancement
commit "$(printf 'Keep the code on screen\n\nFixes #23')" > /dev/null
says "- Keep the code on screen (#23)" v1.4.0 --require-change

# No answer about an issue fails the run, instead of notes that leave it out without a word.
commit "$(printf 'Something\n\nFixes #99')" > /dev/null
status=0
"$script" v1.1.0 > /dev/null 2>&1 || status=$?
[[ $status != 0 ]] || fail "with issue 99 missing: want a failure"
# A previous release git can't find fails the run, instead of notes that say nothing changed.
status=0
"$script" v0.0.99 > /dev/null 2>&1 || status=$?
[[ $status != 0 ]] || fail "with tag v0.0.99 missing: want a failure"
echo "release-notes.sh: all passed"
