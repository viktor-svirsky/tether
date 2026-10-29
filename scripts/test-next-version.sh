#!/usr/bin/env bash
# Tests next-version.sh in a throwaway repo.
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/next-version.sh
repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q -b main
commit() { git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }
expect() {
    local want=$1 got
    shift
    got=$(GITHUB_REF_NAME=main "$script" "$@" 2>&1 | tr '\n' ' ') || true
    [[ $got == "$want" ]] || { echo "next-version.sh $*: want '$want', got '$got'" >&2; exit 1; }
}

commit one
expect "version=1.0.0 previous= " patch
git tag v1.0.0
expect "nothing changed since v1.0.0 " patch
commit two
expect "version=1.0.1 previous=v1.0.0 " patch
expect "version=1.1.0 previous=v1.0.0 " minor
expect "version=2.0.0 previous=v1.0.0 " major
expect "bump is patch, minor or major, not huge " huge
git tag v1.9.9-test
expect "version=1.0.1 previous=v1.0.0 " patch
got=$(GITHUB_REF_NAME=feature "$script" patch 2>&1) && exit 1
[[ $got == "release from main, not feature" ]] || { echo "branch check: got '$got'" >&2; exit 1; }
echo "next-version.sh: all passed"
