#!/usr/bin/env bash
# Builds WireGuard/ (Go) into WireGuard/build/TetherWG.xcframework, for the iPhone, the
# simulator, and the Mac, where `swift test` links it to test WireGuardServer.swift. xcodegen runs it before generating the project (preGenCommand in project.yml).
# It skips the build when the Go sources and the Go version haven't changed since the last one. Needs Go, see go.mod.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
src=$root/WireGuard
out=$src/build
stamp=$out/sources.sha

command -v go >/dev/null || { echo "Go is needed to build WireGuard/, see https://go.dev/dl" >&2; exit 1; }

# The Go version is in the hash too, so a Go upgrade (a fix in net, say) rebuilds.
hash=$({ cd "$src" && cat go.mod go.sum ./*.go "$root/scripts/build-wireguard.sh" && go version; } | shasum | cut -d' ' -f1)
if [[ -d $out/TetherWG.xcframework && -f $stamp && $(cat "$stamp") == "$hash" ]]; then
    exit 0
fi

rm -rf "$out"
mkdir -p "$out"

# One static library per platform and architecture. Go's own iOS support covers the simulator too,
# as long as the C compiler targets it.
build() {
    local sdk=$1 arch=$2 target=$3 dir=$out/$1-$2 goos=ios
    local sysroot
    [[ $sdk == macosx ]] && goos=darwin
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    mkdir -p "$dir"
    CGO_ENABLED=1 GOOS=$goos GOARCH=$arch \
        CC="$(xcrun --sdk "$sdk" -f clang) -isysroot $sysroot -target $target" \
        CGO_CFLAGS="-isysroot $sysroot -target $target" \
        CGO_LDFLAGS="-isysroot $sysroot -target $target" \
        go -C "$src" build -buildmode=c-archive -trimpath -ldflags=-w -o "$dir/libtetherwg.a" .
}

build iphoneos arm64 arm64-apple-ios26.0
build iphonesimulator arm64 arm64-apple-ios26.0-simulator
build iphonesimulator amd64 x86_64-apple-ios26.0-simulator
build macosx arm64 arm64-apple-macos14.0
build macosx amd64 x86_64-apple-macos14.0

for platform in iphoneos iphonesimulator macosx; do
    mkdir -p "$out/$platform/Headers"
    cp "$out/$platform-arm64/libtetherwg.h" "$out/$platform/Headers/TetherWG.h"
    cat > "$out/$platform/Headers/module.modulemap" <<'EOF'
module TetherWG {
    header "TetherWG.h"
    link "resolv"
    export *
}
EOF
done
cp "$out/iphoneos-arm64/libtetherwg.a" "$out/iphoneos/"
lipo -create "$out/macosx-arm64/libtetherwg.a" "$out/macosx-amd64/libtetherwg.a" \
    -output "$out/macosx/libtetherwg.a"
lipo -create "$out/iphonesimulator-arm64/libtetherwg.a" "$out/iphonesimulator-amd64/libtetherwg.a" \
    -output "$out/iphonesimulator/libtetherwg.a"

xcodebuild -create-xcframework \
    -library "$out/iphoneos/libtetherwg.a" -headers "$out/iphoneos/Headers" \
    -library "$out/iphonesimulator/libtetherwg.a" -headers "$out/iphonesimulator/Headers" \
    -library "$out/macosx/libtetherwg.a" -headers "$out/macosx/Headers" \
    -output "$out/TetherWG.xcframework" >/dev/null
rm -rf "$out"/iphoneos* "$out"/iphonesimulator* "$out"/macosx*
echo "$hash" > "$stamp"
