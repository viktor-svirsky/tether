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

    /// The screen stays on while a device is being added, so the iPhone doesn't lock while the
    /// person walks to the laptop and the page stops handing out the config (#44). Not after it connects.
    func testTheScreenStaysAwakeUntilTheDeviceConnects() {
        XCTAssertTrue(progress().keepsScreenAwake)
        XCTAssertTrue(progress(peers: [laptop], hotspotOn: true).keepsScreenAwake, "waiting for its tunnel")
        XCTAssertFalse(progress(peers: [laptop], connected: [laptop.address], hotspotOn: true).keepsScreenAwake)
    }

    /// Removed while the sheet is open, it isn't added any more.
    func testARemovedDeviceGoesBackToTheStart() {
        XCTAssertEqual(progress(peers: [ipad], hotspotOn: true).config, .toDo)
    }

    // MARK: the name typed once it connects

    func testATypedNameIsSavedWithoutTheSpacesAround() {
        XCTAssertEqual(DeviceName.toSave(typed: "  Living room TV ", current: "Device 2"), "Living room TV")
    }

    /// Done without a change saves nothing, so a store that can't save doesn't say a rename failed.
    func testTheNameItHasIsntSavedAgain() {
        XCTAssertNil(DeviceName.toSave(typed: "Device 2", current: "Device 2"))
        XCTAssertNil(DeviceName.toSave(typed: " Device 2  ", current: "Device 2"))
    }

    func testABlankFieldKeepsTheName() {
        XCTAssertNil(DeviceName.toSave(typed: "", current: "Device 2"))
        XCTAssertNil(DeviceName.toSave(typed: "   \n", current: "Device 2"))
    }

    func testOnlyACaseChangeIsStillAChange() {
        XCTAssertEqual(DeviceName.toSave(typed: "ipad", current: "iPad"), "ipad")
    }

    /// Saving cuts a name to 40 characters, so the name is compared as it would be saved. Text
    /// added past 40 changes nothing, and a save then could only report a failure.
    func testANameIsComparedAsItWouldBeSaved() {
        let forty = String(repeating: "x", count: 40)
        XCTAssertNil(DeviceName.toSave(typed: forty + " more", current: forty))
        XCTAssertEqual(DeviceName.toSave(typed: String(repeating: "y", count: 50), current: "iPad"), String(repeating: "y", count: 40))
        XCTAssertEqual(DeviceName.saved("  Kitchen iPad "), "Kitchen iPad")
    }

    // MARK: the naming step, which stays with its device

    private func connected(_ peers: [WireGuardSetup.Peer] = []) -> AddDeviceProgress {
        progress(peers: peers.isEmpty ? [laptop] : peers, connected: [laptop.address], hotspotOn: true)
    }

    func testTheNamingStepStartsWhenTheDeviceConnectsWithItsName() {
        var naming = AddDeviceNaming()
        naming.follow(progress(peers: [laptop], hotspotOn: true))
        XCTAssertNil(naming.device, "not before it connects")
        naming.follow(connected())
        XCTAssertEqual(naming.device, laptop.id)
        XCTAssertEqual(naming.draft, "Device")
    }

    /// Its tunnel dropping and coming back neither ends the step nor resets what was typed.
    func testADisconnectKeepsTheStepAndTheDraft() {
        var naming = AddDeviceNaming()
        naming.follow(connected())
        naming.draft = "Living room"
        naming.follow(progress(peers: [laptop], hotspotOn: true))
        XCTAssertEqual(naming.device, laptop.id, "still naming it while its tunnel is down")
        naming.follow(connected())
        XCTAssertEqual(naming.draft, "Living room", "not reset when it connects again")
    }

    /// A close while its tunnel is down still saves the name.
    func testTheDraftSavesWhileTheTunnelIsDown() throws {
        var naming = AddDeviceNaming()
        naming.follow(connected())
        naming.draft = " Living room "
        let change = try XCTUnwrap(naming.change(in: [ipad, laptop]))
        XCTAssertEqual(change.id, laptop.id)
        XCTAssertEqual(change.name, "Living room")
    }

    func testNothingToSaveWithoutAChangeOrADevice() {
        var naming = AddDeviceNaming()
        XCTAssertNil(naming.change(in: [laptop]), "no step yet")
        naming.follow(connected())
        XCTAssertNil(naming.change(in: [laptop]), "the name it has")
        naming.draft = "Living room"
        XCTAssertNil(naming.change(in: [ipad]), "removed meanwhile")
    }

    // MARK: what VoiceOver hears (#175)

    /// The steps tick off by themselves, so VoiceOver says so without the person moving focus.
    func testEachStepThatTicksOffIsAnnounced() {
        XCTAssertEqual(progress(hotspotOn: true).announcement(after: progress()), "Step 1 done")
        XCTAssertEqual(progress(peers: [laptop], hotspotOn: true).announcement(after: progress(hotspotOn: true)), "Step 2 done")
    }

    func testTheConnectionIsAnnouncedByTheDevicesName() {
        let waiting = progress(peers: [laptop], hotspotOn: true)
        XCTAssertEqual(progress(peers: [laptop], connected: [laptop.address], hotspotOn: true).announcement(after: waiting), "Device is connected")
    }

    /// A scan ticks the last two steps at once: the connection says it all.
    func testAScanIsAnnouncedOnceAsConnected() {
        let scanned = progress(peers: [laptop], connected: [laptop.address], hotspotOn: true)
        XCTAssertEqual(scanned.announcement(after: progress(hotspotOn: true)), "Device is connected")
    }

    func testTwoStepsAtOnceAreAnnouncedTogether() {
        XCTAssertEqual(progress(peers: [laptop], hotspotOn: true).announcement(after: progress()), "Steps 1 and 2 done")
    }

    /// Nothing ticked off: a step going back, the speeds redrawing, or no change at all.
    func testNothingIsAnnouncedWhenNoStepTicksOff() {
        XCTAssertNil(progress().announcement(after: progress()))
        XCTAssertNil(progress().announcement(after: progress(hotspotOn: true)), "the hotspot went off")
        XCTAssertNil(progress(peers: [ipad], hotspotOn: true).announcement(after: progress(hotspotOn: true)), "another device")
    }
}
