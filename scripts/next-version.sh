#!/usr/bin/env bash
# Prints the next release version for the Release workflow, from the last vX.Y.Z tag before HEAD
# and which part goes up (patch, minor or major), as GitHub step outputs. Or release-X.Y, the release
# branch main moved to (see which-release.sh): then it's X.Y.0, if that's after the last release.
#   version=1.2.4
#   previous=v1.2.3   (empty for the first release, which is 1.0.0)
# Refuses to run anywhere but main, and when nothing changed since the last release.
set -euo pipefail

bump=${1:?usage: next-version.sh patch|minor|major|release-X.Y}
[[ $bump =~ ^(patch|minor|major|release-[0-9]+\.[0-9]+)$ ]] || { echo "bump is patch, minor, major or release-X.Y, not $bump" >&2; exit 1; }
# The release branch's own version, as numbers.
branch_major= branch_minor=
if [[ $bump =~ ^release-([0-9]+)\.([0-9]+)$ ]]; then
    branch_major=$((10#${BASH_REMATCH[1]})) branch_minor=$((10#${BASH_REMATCH[2]}))
fi
# The full ref, because GITHUB_REF_NAME is also main for a tag named main. Outside Actions, HEAD's
# ref, which is just HEAD when it's detached.
ref=${GITHUB_REF:-$(git rev-parse --symbolic-full-name HEAD)}
[[ $ref == refs/heads/main ]] || { echo "release from main, not $ref" >&2; exit 1; }

if ! previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude 'v*[!0-9.]*' HEAD 2>/dev/null); then
    echo "version=${branch_major:-1}.${branch_minor:-0}.0"
    echo "previous="
    exit 0
fi
[[ $previous =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "can't read the version in tag $previous" >&2; exit 1; }
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
[[ -n $(git rev-list "$previous..HEAD") ]] || { echo "nothing changed since $previous" >&2; exit 1; }

case $bump in
    patch) echo "version=$major.$minor.$((patch + 1))" ;;
    minor) echo "version=$major.$((minor + 1)).0" ;;
    major) echo "version=$((major + 1)).0.0" ;;
    *)
        (( branch_major > major || (branch_major == major && branch_minor > minor) )) \
            || { echo "$bump isn't after $previous" >&2; exit 1; }
        echo "version=$branch_major.$branch_minor.0"
        ;;
esac
echo "previous=$previous"
