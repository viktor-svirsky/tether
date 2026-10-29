#!/usr/bin/env bash
# Tests next-version.sh in a throwaway repo. Each case checks the exit code, stdout and stderr apart:
# the Release workflow reads stdout as step outputs, and an error that exits 0 would tag a release `v`.
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/next-version.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/repo"
cd "$tmp/repo"
git init -q -b main
commit() { git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }

# run <ref> <args>: runs next-version.sh the way a workflow started on <ref> does, and sets
# status, out and err.
run() {
    local ref=$1
    shift
    status=0
    GITHUB_REF=$ref GITHUB_REF_NAME=${ref#refs/*/} "$script" "$@" > "$tmp/out" 2> "$tmp/err" || status=$?
    out=$(tr '\n' ' ' < "$tmp/out")
    err=$(< "$tmp/err")
}
fail() { echo "next-version.sh $*" >&2; exit 1; }
# ok <stdout> <args>: on main it succeeds, prints <stdout> and nothing on stderr.
ok() {
    local want=$1
    shift
    run refs/heads/main "$@"
    [[ $status == 0 && $out == "$want" && -z $err ]] \
        || fail "$*: want exit 0 and '$want', got exit $status, stdout '$out', stderr '$err'"
}
# refused <ref> <stderr> <args>: started on <ref> it fails, says <stderr> and prints nothing on stdout.
refused() {
    local ref=$1 want=$2
    shift 2
    run "$ref" "$@"
    [[ $status != 0 && -z $out && $err == "$want" ]] \
        || fail "$* on $ref: want a failure saying '$want', got exit $status, stdout '$out', stderr '$err'"
}

commit one
ok "version=1.0.0 previous= " patch
refused refs/heads/main "bump is patch, minor or major, not huge" huge
git tag v1.0.0
refused refs/heads/main "nothing changed since v1.0.0" patch
commit two
ok "version=1.0.1 previous=v1.0.0 " patch
ok "version=1.1.0 previous=v1.0.0 " minor
ok "version=2.0.0 previous=v1.0.0 " major
refused refs/heads/main "bump is patch, minor or major, not huge" huge
git tag v1.9.9-test
ok "version=1.0.1 previous=v1.0.0 " patch
refused refs/heads/feature "release from main, not refs/heads/feature" patch
# A tag named main has GITHUB_REF_NAME main too.
refused refs/tags/main "release from main, not refs/tags/main" patch
echo "next-version.sh: all passed"
