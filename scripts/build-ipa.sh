#!/usr/bin/env bash
# Builds a Tether.ipa with no signing identity for people who sign it themselves (SideStore, AltStore, Feather, a paid
# certificate). The release workflow runs it, and it works the same on any Mac with Xcode:
#   scripts/build-ipa.sh 1.2.0 out/
# Writes out/Tether.ipa and out/LICENSES.txt, the licenses of the code inside it (also in the app),
# and out/xcodebuild.log.
# The build number is the commit count (see project.yml), so it needs the full git history.
set -euo pipefail

(( $# == 2 )) || { echo "usage: build-ipa.sh <version> <output dir>" >&2; exit 2; }
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "the version is X.Y.Z, not '$version'" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$root"
# A shallow clone cuts HEAD's history short and gives too low a build number. Only a cut in HEAD's own
# history counts: a reused checkout can list commits from elsewhere as shallow.
shallow=$(git rev-parse --git-path shallow)
if [[ -f $shallow ]] && grep -qxFf "$shallow" <(git rev-list HEAD); then
    echo "a shallow clone gives the wrong build number, fetch the full history" >&2
    exit 1
fi

xcodegen generate --quiet
# The whole log goes to out/xcodebuild.log, and a failed build prints its errors and its end (#146).
log=$out/xcodebuild.log
if ! xcodebuild archive -project Tether.xcodeproj -scheme Tether -configuration Release \
    -destination generic/platform=iOS -archivePath "$work/Tether.xcarchive" -derivedDataPath "$work/dd" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= MARKETING_VERSION="$version" \
    > "$log" 2>&1; then
    awk '/(^| )error: / && n++ < 20' "$log" >&2
    tail -20 "$log" >&2
    echo "xcodebuild failed, the whole log is $log" >&2
    exit 1
fi
tail -3 "$log"

app=$work/Tether.xcarchive/Products/Applications/Tether.app
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Info.plist") == "$version" ]] \
    || { echo "the app's version isn't $version" >&2; exit 1; }
build=$(git rev-list --count HEAD)
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Info.plist") == "$build" ]] \
    || { echo "the app's build number isn't $build, the commit count" >&2; exit 1; }
[[ $(lipo -archs "$app/Tether") == arm64 ]] || { echo "the app isn't arm64 only" >&2; exit 1; }
# Signing tools re-sign whatever they get, but an ad-hoc or development signature from a build machine
# has no business in a release.
if codesign -d "$app" 2>/dev/null; then
    echo "the app is signed, it should be unsigned" >&2
    exit 1
fi

# The app contains the Go modules' code, and their licenses ask for their text to go with it. The list
# comes from what the iOS build links, so a new module brings its license along.
licenses=$out/LICENSES.txt
{
    echo "Tether"
    echo
    cat LICENSE
    GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go -C WireGuard list -deps \
        -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Version}} {{.Dir}}{{end}}{{end}}' . | sort -u |
        while read -r module modversion dir; do
            files=$(find "$dir" -maxdepth 1 -type f \( -iname 'licen[cs]e*' -o -iname 'copying*' -o -iname 'notice*' \))
            [[ -n $files ]] || { echo "$module has no license file" >&2; exit 1; }
            for file in $files; do
                printf '\n\n%s %s, %s\n\n' "$module" "$modversion" "$(basename "$file")"
                cat "$file"
            done
        done
} > "$licenses"
cp "$licenses" "$app/"

# The build itself stays unsigned, as checked above. This ad-hoc signature has no identity and is
# there only so the entitlements travel: SideStore, AltStore and other signers read the app group from
# it and keep it when they sign, and without it the widgets have no way to Tether's state. The
# extension first, since the app's signature covers it.
appex=$app/PlugIns/TetherWidgets.appex
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$appex/Info.plist") == "$build" ]] \
    || { echo "the widget extension's build number isn't $build, the app's" >&2; exit 1; }
# The entitlements files name the group by $(APP_BUNDLE_ID), which Xcode fills in only when it signs.
group=$(/usr/libexec/PlistBuddy -c "Print :TetherAppGroup" "$app/Info.plist")
[[ $group =~ ^group\.[A-Za-z0-9.-]+$ ]] || { echo "the app's group is '$group', not group.<bundle ID>" >&2; exit 1; }
for file in Widgets/TetherWidgets.entitlements Sources/Tether.entitlements; do
    sed 's/group\.\$(APP_BUNDLE_ID)/'"$group"'/' "$file" > "$work/$(basename "$file")"
    # A file that no longer names the group that way would be signed in with the placeholder.
    grep -qF "<string>$group</string>" "$work/$(basename "$file")" || { echo "$file doesn't name the group as group.\$(APP_BUNDLE_ID)" >&2; exit 1; }
done
codesign -f -s - --entitlements "$work/TetherWidgets.entitlements" "$appex"
codesign -f -s - --entitlements "$work/Tether.entitlements" "$app"

mkdir "$work/Payload"
cp -R "$app" "$work/Payload/"
rm -f "$out/Tether.ipa"
(cd "$work" && zip -qry "$out/Tether.ipa" Payload)
echo "$out/Tether.ipa"
