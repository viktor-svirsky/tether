// swift-tools-version:5.9
// Only for `swift test` on the Mac. The app itself builds from project.yml. TetherWG is the
// WireGuard server in Go: run scripts/build-wireguard.sh first (xcodegen runs it too).
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: [
        .target(name: "TetherCore", dependencies: ["TetherWG"], path: "Sources", sources: ["Traffic.swift", "WireGuardSetup.swift", "WireGuardServer.swift", "AppExpiry.swift", "KeepAlivePolicy.swift", "Format.swift", "ShortcutReply.swift", "HotspotSession.swift"]),
        .binaryTarget(name: "TetherWG", path: "WireGuard/build/TetherWG.xcframework"),
        .testTarget(name: "TetherTests", dependencies: ["TetherCore"], path: "Tests"),
    ]
)
