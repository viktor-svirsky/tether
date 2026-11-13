import Foundation

/// The config as a .conf file to share. WireGuard names the tunnel after the file. It holds a
/// private key, so it lives in the temporary directory, and only while Add a device needs it, see
/// `ReadyCode.forget`.
enum ConfigFile {
    /// Where the files go. Tests use their own.
    nonisolated(unsafe) static var directory = FileManager.default.temporaryDirectory

    static func write(_ config: String, named name: String) -> URL? {
        let url = directory.appendingPathComponent(WireGuardSetup.fileName(for: name))
        return (try? config.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }

    /// Every config file in the folder, the ones from before a crash too.
    static func removeAll() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("Tether") && name.hasSuffix(".conf") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
