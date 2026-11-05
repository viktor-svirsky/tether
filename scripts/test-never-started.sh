#!/usr/bin/env bash
# Tests never-started.sh, which decides from a run's jobs (GitHub's API) whether the run was cancelled
# because no runner ever started it (#87). A wrong yes reruns a run someone cancelled on purpose, or
# one a newer push replaced, and a wrong no leaves a branch waiting on a manual rerun.
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/never-started.sh
fail() { echo "never-started.sh: $*" >&2; exit 1; }
# says <yes|no> <jobs JSON>
says() {
    local want=$1 jobs=$2 status=0
    printf '%s' "$jobs" | "$script" || status=$?
    case $want in
        yes) [[ $status == 0 ]] || fail "want yes (0), got $status for $jobs" ;;
        no) [[ $status == 1 ]] || fail "want no (1), got $status for $jobs" ;;
    esac
}

# What a run cancelled after 15 minutes with no runner looks like: no steps, no runner.
says yes '{"jobs":[{"name":"test","conclusion":"cancelled","steps":[],"runner_name":null}]}'
says yes '{"jobs":[{"name":"test","conclusion":"cancelled","steps":[],"runner_name":""}]}'
# One job never started, another passed: rerun (only the failed and cancelled jobs go again).
says yes '{"jobs":[{"name":"a","conclusion":"success","steps":[{"name":"x"}],"runner_name":"r"},{"name":"b","conclusion":"cancelled","steps":[],"runner_name":null}]}'
# Cancelled after it started, by a person or a newer push: no.
says no '{"jobs":[{"name":"test","conclusion":"cancelled","steps":[{"name":"Set up job"}],"runner_name":"GitHub Actions 12"}]}'
# A runner picked it up but it was cancelled before its first step: it started, so no.
says no '{"jobs":[{"name":"test","conclusion":"cancelled","steps":[],"runner_name":"GitHub Actions 12"}]}'
# Failed for real: no.
says no '{"jobs":[{"name":"test","conclusion":"failure","steps":[{"name":"Unit tests"}],"runner_name":"r"}]}'
# Skipped jobs (a pull request from this repo's own branch) have no steps either: no.
says no '{"jobs":[{"name":"test","conclusion":"skipped","steps":[],"runner_name":null}]}'
# Nothing to read: no.
says no '{"jobs":[]}'
printf 'not json' | "$script" 2> /dev/null && fail "bad input should fail"
echo "never-started.sh: all good"
