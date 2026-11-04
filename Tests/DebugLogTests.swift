import XCTest
@testable import TetherCore

/// The log Settings shares: each line with its time, the Go server's lines in their place, nothing
/// secret on disk, and a size it never goes over.
final class DebugLogTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_793_788_953.12) // 2026-11-04 10:42:33.120 UTC
    private var goLines: [DebugLog.Line] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DebugLogTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLog(segmentLimit: Int = DebugLog.segmentLimit) -> DebugLog {
        DebugLog(directory: directory, segmentLimit: segmentLimit, timeZone: TimeZone(identifier: "UTC")!,
                 now: { [unowned self] in clock },
                 source: { [unowned self] in defer { goLines = [] }; return goLines })
    }

    /// Every byte the log keeps on disk.
    private func onDisk() throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    private func lines(_ export: String) -> [String] {
        export.split(separator: "\n").map(String.init).filter { $0.hasPrefix("2026-") }
    }

    func testEachLineHasItsTime() {
        let log = makeLog()
        log.append("binding to 172.20.10.1")
        clock += 1.5
        log.append("WireGuard on 172.20.10.1:51820, 2 devices")
        XCTAssertEqual(lines(log.export(header: "")), [
            "2026-11-04 10:42:33.120 binding to 172.20.10.1",
            "2026-11-04 10:42:34.620 WireGuard on 172.20.10.1:51820, 2 devices",
        ])
    }

    /// The Go server's lines carry their own times, from before the Swift line that takes them.
    func testGoLinesComeInTheirPlaceWithTheirOwnTimes() {
        let log = makeLog()
        log.append("binding to 172.20.10.1")
        goLines = [DebugLog.Line(at: clock + 0.2, text: "go: Interface state was Down, requested Up, now Up"),
                   DebugLog.Line(at: clock + 0.3, text: "go: device 10.7.0.2 - Received handshake initiation")]
        clock += 1
        log.append("WireGuard: a new device connected with the QR code")
        XCTAssertEqual(lines(log.export(header: "")), [
            "2026-11-04 10:42:33.120 binding to 172.20.10.1",
            "2026-11-04 10:42:33.320 go: Interface state was Down, requested Up, now Up",
            "2026-11-04 10:42:33.420 go: device 10.7.0.2 - Received handshake initiation",
            "2026-11-04 10:42:34.120 WireGuard: a new device connected with the QR code",
        ])
    }

    /// The watcher takes the Go server's lines when Swift has nothing to say.
    func testTakingTheGoLinesAloneWritesThem() {
        let log = makeLog()
        goLines = [DebugLog.Line(at: clock, text: "go: Device closing")]
        log.takeSource()
        XCTAssertEqual(lines(log.export(header: "")), ["2026-11-04 10:42:33.120 go: Device closing"])
    }

    /// A real client config, keys and all, goes through the whole write path: none of either key
    /// reaches the disk, in base64 or in hex.
    func testNoKeyEverReachesTheDisk() throws {
        var setup = WireGuardSetup.new()
        setup.prepareReady()
        let ready = try XCTUnwrap(setup.ready)
        let config = setup.clientConfig(for: ready, host: "2607:fb91:8a1c:3e40::1")
        let log = makeLog()
        log.append("config: \(config)")
        goLines = [DebugLog.Line(at: clock, text: "go: private_key=\(setup.serverPrivateKey.hex)")]
        log.append("server key \(setup.serverPublicKey.base64EncodedString())")
        let disk = try onDisk()
        let export = log.export(header: "")
        for key in [ready.privateKey, ready.publicKey, setup.serverPrivateKey, setup.serverPublicKey] {
            for text in [key.base64EncodedString(), key.hex] {
                for start in stride(from: 0, to: text.count - 20, by: 4) {
                    let piece = String(text.dropFirst(start).prefix(20))
                    XCTAssertFalse(disk.contains(piece), "a piece of a key on disk: \(piece)")
                    XCTAssertFalse(export.contains(piece), "a piece of a key in the export: \(piece)")
                }
            }
        }
        XCTAssertFalse(disk.contains("8a1c"), "the full IPv6 address stayed out too")
        XCTAssertTrue(disk.contains("[key]"))
    }

    /// The disk holds two segments at most, so the log and its export stay under twice the limit,
    /// and the newest lines are the ones kept.
    func testItStaysUnderItsSizeCap() throws {
        let limit = 2_000
        let log = makeLog(segmentLimit: limit)
        for i in 1...500 {
            clock += 1
            log.append("line \(i) of a long session")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let size = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(size, 2 * limit)
        let export = log.export(header: "")
        XCTAssertLessThanOrEqual(export.utf8.count, 2 * limit + 100, "the two files and a short header")
        XCTAssertTrue(export.hasSuffix("line 500 of a long session\n"))
        XCTAssertFalse(export.contains("line 1 of"), "the oldest are gone")
        let kept = lines(export)
        XCTAssertGreaterThan(kept.count, limit / 60, "at least a segment's worth is kept")
        XCTAssertEqual(kept, kept.sorted(), "in order across the two segments")
    }

    func testTheDefaultCapKeepsAFewThousandLines() {
        XCTAssertEqual(DebugLog.segmentLimit, 256 * 1024)
        XCTAssertGreaterThan(DebugLog.segmentLimit / 80, 3_000, "lines are about 80 bytes")
    }

    /// The lines of an earlier launch are still there.
    func testALaunchKeepsTheLinesBeforeIt() {
        makeLog().append("before the relaunch")
        clock += 60
        let log = makeLog()
        log.append("after the relaunch")
        XCTAssertEqual(lines(log.export(header: "")).count, 2)
    }

    /// iOS may empty Caches while Tether runs. The next line starts the log again.
    func testALogEmptiedUnderneathStartsAgain() throws {
        let log = makeLog(segmentLimit: 200)
        log.append("before")
        log.append("still before, enough to fill most of the first file")
        try FileManager.default.removeItem(at: directory)
        log.append("after the folder went")
        log.append("and one more")
        XCTAssertEqual(lines(log.export(header: "")).map { String($0.dropFirst(24)) }, ["after the folder went", "and one more"])
        XCTAssertFalse(log.export(header: "").contains("couldn't be saved"))
    }

    func testTheExportStartsWithItsHeaderAndIsATextFile() throws {
        let log = makeLog()
        log.append("binding to 172.20.10.1")
        let url = try log.writeExport(header: "Tether 1.6.0 (140), Version 26.1 (Build 23B85)", to: directory.appendingPathComponent("out"))
        XCTAssertEqual(url.lastPathComponent, "Tether log.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Tether 1.6.0 (140), Version 26.1 (Build 23B85)\nTimes are in GMT.\n\n"), text)
        XCTAssertTrue(text.hasSuffix("2026-11-04 10:42:33.120 binding to 172.20.10.1\n"))
        // Sharing again replaces it.
        log.append("one more")
        let again = try log.writeExport(header: "h", to: directory.appendingPathComponent("out"))
        XCTAssertEqual(again, url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("one more"))
    }

    func testAnEmptyLogSaysSo() {
        XCTAssertTrue(makeLog().export(header: "h").hasSuffix("Nothing logged yet.\n"))
    }

    /// A log that can't be written loses its lines, says how many, and never stops the app.
    func testALogThatCantBeWrittenSaysHowManyLinesItLost() throws {
        try Data("a file where the folder should be".utf8).write(to: directory)
        let log = makeLog()
        log.append("lost")
        log.append("lost too")
        XCTAssertTrue(log.export(header: "").contains("2 lines couldn't be saved."))
    }

    /// Model logs from the main actor and the share sheet exports from wherever it runs.
    func testLinesFromManyThreadsAreAllKept() {
        let log = DebugLog(directory: directory, source: { [] })
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            log.append("line \(i)")
            if i % 50 == 0 { _ = log.export(header: "") }
        }
        let export = log.export(header: "")
        XCTAssertEqual(export.split(separator: "\n").filter { $0.contains(" line ") }.count, 200)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
