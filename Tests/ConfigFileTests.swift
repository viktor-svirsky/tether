import XCTest
@testable import TetherCore

/// The shared config holds a private key, so no copy stays behind (#183).
final class ConfigFileTests: XCTestCase {
    private var folder: URL!
    private var before: URL!

    override func setUpWithError() throws {
        before = ConfigFile.directory
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ConfigFile.directory = folder
    }

    override func tearDownWithError() throws {
        ConfigFile.directory = before
        try? FileManager.default.removeItem(at: folder)
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testRemovingLeavesNoConfigButOtherFilesStay() throws {
        let url = try XCTUnwrap(ConfigFile.write("[Interface]\n", named: ""))
        XCTAssertEqual(url.lastPathComponent, "Tether.conf")
        try Data("old".utf8).write(to: folder.appendingPathComponent("Tether-Device-2.conf")) // left by a crash
        try Data("x".utf8).write(to: folder.appendingPathComponent("other.txt"))
        ConfigFile.removeAll()
        XCTAssertEqual(try files(), ["other.txt"])
    }
}
