import XCTest
@testable import TetherCore

/// Which device Add a device follows, and when it keeps the screen on (#181).
final class AddDeviceFollowTests: XCTestCase {
    private let laptop = WireGuardSetup.Peer(name: "Device", publicKey: Data(), address: "10.7.0.4")
    private let ipad = WireGuardSetup.Peer(name: "iPad", publicKey: Data(), address: "10.7.0.2")
    private let next = WireGuardSetup.Peer(name: "Device 3", publicKey: Data(), address: "10.7.0.5")

    func testItFollowsTheCodeReadyWhenTheSheetOpened() {
        XCTAssertEqual(AddDeviceFollow(follows: nil, ready: laptop.id).ready, laptop.id)
        XCTAssertNil(AddDeviceFollow(follows: nil, ready: nil).ready, "no code")
    }

    /// The `addDeviceWaiting` and `addDeviceDone` demos open on a listed device.
    func testADemoOpensOnTheDeviceItFollows() {
        XCTAssertEqual(AddDeviceFollow(follows: ipad.id, ready: laptop.id).ready, ipad.id)
    }

    /// After starting over, say: the old code was never claimed, so the new one is the device.
    func testUntilItsClaimedANewCodeTakesItsPlace() {
        var follow = AddDeviceFollow(follows: nil, ready: laptop.id)
        follow.readyChanged(to: next.id, peers: [ipad])
        XCTAssertEqual(follow.ready, next.id)
    }

    /// A download or its first handshake lists the device, and a new code is made for the next one.
    func testOnceClaimedANewCodeLeavesIt() {
        var follow = AddDeviceFollow(follows: nil, ready: laptop.id)
        follow.readyChanged(to: next.id, peers: [ipad, laptop])
        XCTAssertEqual(follow.ready, laptop.id)
    }

    /// A new code that can't be saved leaves none, and the sheet follows nothing.
    func testNoNewCodeLeavesNothingToFollow() {
        var follow = AddDeviceFollow(follows: nil, ready: laptop.id)
        follow.readyChanged(to: nil, peers: [ipad])
        XCTAssertNil(follow.ready)
        follow.readyChanged(to: next.id, peers: [ipad])
        XCTAssertEqual(follow.ready, next.id, "and the next code is followed")
    }

    /// Removed while the sheet is open, it isn't listed any more, so the next code takes its place.
    func testARemovedDeviceIsReplacedByTheNextCode() {
        var follow = AddDeviceFollow(follows: nil, ready: laptop.id)
        follow.readyChanged(to: next.id, peers: [ipad, laptop])
        XCTAssertEqual(follow.ready, laptop.id, "claimed")
        follow.readyChanged(to: next.id, peers: [ipad])
        XCTAssertEqual(follow.ready, next.id, "removed")
    }

    func testItsProgressIsTheFollowedDevices() {
        let follow = AddDeviceFollow(follows: nil, ready: laptop.id)
        XCTAssertEqual(follow.progress(peers: [ipad, laptop], connected: [ipad.address], hotspotOn: true),
                       AddDeviceProgress(ready: laptop.id, peers: [ipad, laptop], connected: [ipad.address], hotspotOn: true))
    }

    // MARK: the screen kept on

    /// Only on the WireGuard steps, until the device connects: the page hands out the config only
    /// while Tether is on screen. The proxy works with the screen off.
    func testTheScreenStaysOnOnlyOnTheWireGuardStepsUntilItConnects() {
        let follow = AddDeviceFollow(follows: nil, ready: laptop.id)
        let waiting = follow.progress(peers: [laptop], connected: [], hotspotOn: true)
        let connected = follow.progress(peers: [laptop], connected: [laptop.address], hotspotOn: true)
        XCTAssertTrue(AddDeviceFollow.keepsScreenAwake(on: .wireGuard, waiting))
        XCTAssertFalse(AddDeviceFollow.keepsScreenAwake(on: .wireGuard, connected), "connected")
        XCTAssertFalse(AddDeviceFollow.keepsScreenAwake(on: .proxy, waiting), "the proxy")
        XCTAssertFalse(AddDeviceFollow.keepsScreenAwake(on: nil, waiting), "the first question")
    }

    /// Giving a device a new config (M1): the sheet follows that device by its id, and it counts as
    /// claimed once its key is the code's. A new code doesn't take its place.
    func testANewConfigIsFollowedByTheDevicesKey() {
        let oldKey = WireGuardSetup.Peer(name: "Windows PC", publicKey: Data([1]), address: "10.7.0.3")
        var follow = AddDeviceFollow(follows: nil, ready: next.id, replacing: oldKey)
        let waiting = follow.progress(peers: [ipad, oldKey], connected: ["10.7.0.3"], hotspotOn: true)
        XCTAssertNil(waiting.device, "the old config connecting is not the new one")
        XCTAssertEqual(waiting.config, .toDo)
        follow.readyChanged(to: laptop.id, peers: [ipad, oldKey])
        var claimed = oldKey
        claimed.publicKey = Data([2])
        claimed.address = "10.7.0.5"
        let listed = follow.progress(peers: [ipad, claimed], connected: [], hotspotOn: true)
        XCTAssertEqual(listed.device, claimed)
        XCTAssertEqual(listed.tunnel, .waiting)
        XCTAssertTrue(follow.progress(peers: [ipad, claimed], connected: ["10.7.0.5"], hotspotOn: true).finished)
    }
}
