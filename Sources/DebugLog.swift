import Foundation

/// The log Settings shares for a bug report (#77): Tether's lines and the Go server's, each with its
/// time, in a file that outlives a relaunch. Every line goes through `LogRedaction` before it's
/// written, so the disk never holds a key or a full address. Two files take turns: once the current
/// one would pass `segmentLimit`, it replaces the previous one, so the log never holds more than two
/// of them, the newest lines. Safe from any thread: the share sheet exports wherever it runs.
/// Foundation only.
final class DebugLog: @unchecked Sendable {
    struct Line: Equatable {
        let at: Date
        let text: String
    }

    /// Lines are about 80 bytes, so the two files hold about 3,000 to 6,000 of them.
    static let segmentLimit = 256 * 1024

    /// In Caches, which iOS may empty when the iPhone runs out of space, and which isn't backed up.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Log")
    }

    private let directory: URL
    private let segmentLimit: Int
    private let timeZone: TimeZone
    private let now: () -> Date
    private let source: () -> [Line]
    private let stamp: DateFormatter
    private let lock = NSLock()
    /// Lines that couldn't be written, said in the export.
    private var unsaved = 0

    private var current: URL { directory.appendingPathComponent("current.log") }
    private var previous: URL { directory.appendingPathComponent("previous.log") }

    /// `source` hands over the Go server's lines since it was last asked, see `WireGuardServer.takeLog`.
    /// They're written before each of Tether's own, so the file is in the order things happened.
    init(directory: URL, segmentLimit: Int = DebugLog.segmentLimit, timeZone: TimeZone = .current,
         now: @escaping () -> Date = Date.init, source: @escaping () -> [Line]) {
        self.directory = directory
        self.segmentLimit = segmentLimit
        self.timeZone = timeZone
        self.now = now
        self.source = source
        stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = timeZone
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func append(_ text: String) {
        lock.withLock { write(source() + [Line(at: now(), text: text)]) }
    }

    /// Writes the Go server's lines that came since the last line, for when Tether has nothing to say.
    func takeSource() {
        lock.withLock {
            let lines = source()
            if !lines.isEmpty { write(lines) }
        }
    }

    /// Runs with the lock held.
    private func write(_ lines: [Line]) {
        let data = Data(lines.map { "\(stamp.string(from: $0.at)) \(LogRedaction.redact($0.text))\n" }.joined().utf8)
        do {
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            // Read each time: iOS may empty Caches while Tether runs.
            let size = (try? files.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
            if size > 0, size + data.count > segmentLimit {
                try? files.removeItem(at: previous)
                try files.moveItem(at: current, to: previous)
            }
            // Created only when it isn't there, so a failed open never starts the file over.
            if !files.fileExists(atPath: current.path) { try Data().write(to: current) }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            unsaved += lines.count
        }
    }

    /// The log to share: `header` (what this build and iOS are), the time zone of the times, and the lines, oldest first.
    func export(header: String) -> String {
        lock.withLock {
            let body = [previous, current].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
            var out = header.isEmpty ? "" : header + "\n"
            let zone = timeZone.abbreviation().map { $0 == timeZone.identifier ? $0 : "\(timeZone.identifier) (\($0))" } ?? timeZone.identifier
            out += "Times are in \(zone).\n"
            if unsaved > 0 { out += "\(unsaved) \(unsaved == 1 ? "line" : "lines") couldn't be saved.\n" }
            return out + "\n" + (body.isEmpty ? "Nothing logged yet.\n" : body)
        }
    }

    /// `export` as "Tether log.txt" in `directory`, replacing the last one.
    func writeExport(header: String, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Tether log.txt")
        try export(header: header).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
