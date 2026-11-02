import XCTest
@testable import TetherCore

/// How far adding one device has got: the device behind the code that was ready when the sheet opened.
final class AddDeviceProgressTests: XCTestCase {
    private let laptop = WireGuardSetup.Peer(name: "Device", publicKey: Data(), address: "10.7.0.4")
    private let ipad = WireGuardSetup.Peer(name: "iPad", publicKey: Data(), address: "10.7.0.2")

    private func progress(peers: [WireGuardSetup.Peer] = [], connected: Set<String> = [], hotspotOn: Bool = false) -> AddDeviceProgress {
        AddDeviceProgress(ready: laptop.id, peers: peers, connected: connected, hotspotOn: hotspotOn)
    }

    func testAtFirstEveryStepIsToDo() {
        let p = progress()
        XCTAssertEqual([p.joined, p.config, p.tunnel], [.toDo, .toDo, .toDo])
        XCTAssertNil(p.device)
        XCTAssertFalse(p.finished)
    }

    func testTheHotspotBeingOnTicksTheFirstStep() {
        let p = progress(hotspotOn: true)
        XCTAssertEqual([p.joined, p.config, p.tunnel], [.done, .toDo, .toDo])
    }

    /// A download from the page lists the device before its tunnel is on.
    func testADownloadListsTheDeviceAndTheTunnelIsAwaited() {
        let p = progress(peers: [ipad, laptop], hotspotOn: true)
        XCTAssertEqual([p.joined, p.config, p.tunnel], [.done, .done, .waiting])
        XCTAssertEqual(p.device?.name, "Device")
        XCTAssertFalse(p.finished)
    }

    func testItsFirstConnectionFinishesIt() {
        let p = progress(peers: [ipad, laptop], connected: [laptop.address], hotspotOn: true)
        XCTAssertEqual([p.joined, p.config, p.tunnel], [.done, .done, .done])
        XCTAssertTrue(p.finished)
    }

    /// A scanned code is listed only by its first handshake, so the last two steps tick together.
    func testAScanTicksEverythingAtItsFirstHandshake() {
        let p = progress(peers: [laptop], connected: [laptop.address], hotspotOn: false)
        XCTAssertEqual([p.joined, p.config, p.tunnel], [.done, .done, .done], "a connection means it joined")
    }

    /// Only the code's own device counts: not one listed before, connected or not.
    func testOtherDevicesDontCount() {
        let p = progress(peers: [ipad], connected: [ipad.address], hotspotOn: true)
        XCTAssertEqual([p.config, p.tunnel], [.toDo, .toDo])
        XCTAssertNil(p.device)
    }

    func testWithNoCodeNothingIsAdded() {
        let p = AddDeviceProgress(ready: nil, peers: [ipad], connected: [ipad.address], hotspotOn: true)
        XCTAssertEqual([p.joined, p.config, p.tunnel], [.done, .toDo, .toDo])
        XCTAssertNil(p.device)
    }

    /// Removed while the sheet is open, it isn't added any more.
    func testARemovedDeviceGoesBackToTheStart() {
        XCTAssertEqual(progress(peers: [ipad], hotspotOn: true).config, .toDo)
    }
}
