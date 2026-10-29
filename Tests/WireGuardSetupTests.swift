import CryptoKit
import Security
import XCTest
@testable import TetherCore

final class WireGuardSetupTests: XCTestCase {
    func testANewSetupHasAServerKeyAndNoDevices() {
        let setup = WireGuardSetup.new()
        XCTAssertEqual(setup.serverPrivateKey.count, 32)
        XCTAssertEqual(setup.serverPublicKey.count, 32)
        XCTAssertTrue(setup.peers.isEmpty)
        XCTAssertNotEqual(WireGuardSetup.new().serverPrivateKey, setup.serverPrivateKey)
    }

    func testThePublicKeyIsTheX25519OfThePrivateOne() throws {
        let setup = WireGuardSetup.new()
        let expected = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: setup.serverPrivateKey).publicKey.rawRepresentation
        XCTAssertEqual(setup.serverPublicKey, expected)
    }

    func testDevicesGetTheLowestFreeAddress() throws {
        var setup = WireGuardSetup.new()
        let a = try XCTUnwrap(setup.addPeer(name: "iPad"))
        let b = try XCTUnwrap(setup.addPeer(name: "Mac"))
        XCTAssertEqual(a.address, "10.7.0.2")
        XCTAssertEqual(b.address, "10.7.0.3")
        setup.removePeer(a.id)
        XCTAssertEqual(setup.addPeer(name: "Phone")?.address, "10.7.0.2")
        XCTAssertNotEqual(a.publicKey, b.publicKey)
    }

    func testTheSubnetFillsUp() {
        var setup = WireGuardSetup.new()
        for i in 0..<253 { XCTAssertNotNil(setup.addPeer(name: "d\(i)")) }
        XCTAssertNil(setup.addPeer(name: "one too many"))
    }

    func testAnEmptyNameGetsADefault() {
        var setup = WireGuardSetup.new()
        XCTAssertEqual(setup.addPeer(name: "  ")?.name, "Device")
        XCTAssertEqual(setup.addPeer(name: "")?.name, "Device 2")
    }

    func testTheClientConfig() throws {
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: "iPad"))
        let config = setup.clientConfig(for: peer)
        XCTAssertEqual(config, """
            [Interface]
            PrivateKey = \(peer.privateKey.base64EncodedString())
            Address = 10.7.0.2/32
            DNS = 1.1.1.1
            MTU = 1420

            [Peer]
            PublicKey = \(setup.serverPublicKey.base64EncodedString())
            Endpoint = 172.20.10.1:51820
            AllowedIPs = 0.0.0.0/0, ::/0
            PersistentKeepalive = 25

            """)
    }

    func testAKeyThatIsNotAKeyHasNoPublicKey() {
        XCTAssertEqual(WireGuardSetup.publicKey(of: Data([1, 2, 3])), Data())
        XCTAssertEqual(WireGuardSetup.publicKey(of: Data()), Data())
    }

    func testADefaultNameSkipsOneAlreadyTaken() {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "Device")
        _ = setup.addPeer(name: "Device 2")
        _ = setup.addPeer(name: "Device 4")
        XCTAssertEqual(setup.addPeer(name: "")?.name, "Device 3")
        XCTAssertEqual(setup.addPeer(name: "")?.name, "Device 5")
    }

    func testRenamingKeepsAnythingButABlankName() throws {
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: ""))
        setup.renamePeer(peer.id, to: "  Kitchen iPad ")
        XCTAssertEqual(setup.peers[0].name, "Kitchen iPad")
        setup.renamePeer(peer.id, to: "   ")
        XCTAssertEqual(setup.peers[0].name, "Kitchen iPad", "a blank name leaves the old one")
        setup.renamePeer(peer.id, to: String(repeating: "x", count: 100))
        XCTAssertEqual(setup.peers[0].name.count, 40)
    }

    // MARK: the ready device behind the QR code on the main screen

    func testTheReadyDeviceIsLetInButNotListed() throws {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        setup.prepareReady()
        let ready = try XCTUnwrap(setup.ready)
        XCTAssertEqual(ready.address, "10.7.0.3", "the next free address")
        XCTAssertEqual(setup.peers.map(\.name), ["iPad"], "nobody has used it yet")
        XCTAssertEqual(setup.serverPeers.map(\.address), ["10.7.0.2", "10.7.0.3"], "but whoever scans it can connect")
        let again = ready
        setup.prepareReady()
        XCTAssertEqual(setup.ready, again, "the same code until someone uses it")
    }

    func testUsingTheReadyDeviceListsItAndMakesANewOne() throws {
        var setup = WireGuardSetup.new()
        setup.prepareReady()
        let first = try XCTUnwrap(setup.ready)
        XCTAssertTrue(setup.claimReady(address: first.address))
        XCTAssertEqual(setup.peers.map(\.id), [first.id])
        XCTAssertEqual(setup.peers[0].name, "Device")
        let next = try XCTUnwrap(setup.ready)
        XCTAssertNotEqual(next.publicKey, first.publicKey)
        XCTAssertEqual(next.address, "10.7.0.3")
        XCTAssertTrue(setup.claimReady(address: next.address))
        XCTAssertEqual(setup.peers.map(\.name), ["Device", "Device 2"])
    }

    func testOnlyTheReadyDevicesAddressClaimsIt() {
        var setup = WireGuardSetup.new()
        setup.prepareReady()
        let ready = setup.ready
        XCTAssertFalse(setup.claimReady(address: "10.7.0.9"))
        XCTAssertEqual(setup.ready, ready)
        XCTAssertTrue(setup.peers.isEmpty)
    }

    func testAFullSubnetHasNoReadyDevice() {
        var setup = WireGuardSetup.new()
        for i in 0..<253 { _ = setup.addPeer(name: "d\(i)") }
        setup.prepareReady()
        XCTAssertNil(setup.ready)
        XCTAssertFalse(setup.claimReady(address: "10.7.0.2"))
    }

    func testTheStorePreparesAReadyDeviceForAnOlderSetup() throws {
        let secrets = InMemorySecrets()
        var old = WireGuardSetup.new()
        _ = old.addPeer(name: "UTR")
        secrets.data = try JSONEncoder().encode(old) // saved before ready devices existed: no "ready" key
        XCTAssertFalse(String(decoding: try XCTUnwrap(secrets.data), as: UTF8.self).contains("\"ready\""))
        let devices = WireGuardDevices(secrets: secrets)
        XCTAssertEqual(devices.setup.peers.map(\.name), ["UTR"])
        let ready = try XCTUnwrap(devices.setup.ready)
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.ready, ready, "saved, so the QR code stays the same after a relaunch")
    }

    func testAClaimIsSaved() throws {
        let secrets = InMemorySecrets()
        let devices = WireGuardDevices(secrets: secrets)
        let ready = try XCTUnwrap(devices.setup.ready)
        XCTAssertTrue(devices.claimReady(address: ready.address))
        let reloaded = WireGuardDevices(secrets: secrets).setup
        XCTAssertEqual(reloaded.peers.map(\.id), [ready.id])
        XCTAssertNotNil(reloaded.ready)
    }

    func testAClaimThatCantBeSavedChangesNothing() throws {
        let secrets = FlakySecrets()
        let devices = WireGuardDevices(secrets: secrets)
        let ready = try XCTUnwrap(devices.setup.ready)
        secrets.savesFail = true
        XCTAssertFalse(devices.claimReady(address: ready.address))
        XCTAssertEqual(devices.setup.ready, ready)
        XCTAssertTrue(devices.setup.peers.isEmpty)
    }

    func testAnUnreadableSetupHasAReasonToShow() {
        XCTAssertEqual("\(WireGuardDevices.Unreadable())", "the saved WireGuard setup can't be read")
    }

    func testTheConfigFileNameIsSafe() {
        XCTAssertEqual(WireGuardSetup.fileName(for: "Viktor's iPad"), "Tether-Viktor-s-iPad.conf")
        XCTAssertEqual(WireGuardSetup.fileName(for: "///"), "Tether.conf")
    }

    func testItSurvivesARoundTrip() throws {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        let data = try JSONEncoder().encode(setup)
        XCTAssertEqual(try JSONDecoder().decode(WireGuardSetup.self, from: data), setup)
    }

    func testASetupSavedWithRoutersAndKindsStillLoads() throws {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "UTR")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        json["peers"] = try XCTUnwrap(json["peers"] as? [[String: Any]]).map {
            var p = $0
            p["kind"] = "router"
            p["isRouter"] = true
            return p
        }
        let old = try JSONDecoder().decode(WireGuardSetup.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old, setup, "the router switch and the kind of older versions are ignored, the server finds a router itself")
    }

    func testANameIsSaved() {
        let secrets = InMemorySecrets()
        let devices = WireGuardDevices(secrets: secrets)
        let peer = devices.connectReady()!
        XCTAssertTrue(devices.rename(peer.id, to: "Kitchen iPad"))
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.peers.map(\.name), ["Kitchen iPad"])
    }

    func testANameThatCantBeSavedIsntChanged() {
        let secrets = FlakySecrets()
        let devices = WireGuardDevices(secrets: secrets)
        let peer = devices.connectReady()!
        secrets.savesFail = true
        XCTAssertFalse(devices.rename(peer.id, to: "Kitchen iPad"))
        XCTAssertEqual(devices.setup.peers[0].name, "Device", "not shown, since it wouldn't be there after a relaunch")
    }

    func testTheStoreCreatesASetupOnceAndKeepsIt() {
        let secrets = InMemorySecrets()
        let first = WireGuardDevices(secrets: secrets)
        _ = first.connectReady()
        let second = WireGuardDevices(secrets: secrets)
        XCTAssertEqual(second.setup, first.setup)
        XCTAssertEqual(second.setup.peers.map(\.name), ["Device"])
        second.remove(second.setup.peers[0].id)
        XCTAssertTrue(WireGuardDevices(secrets: secrets).setup.peers.isEmpty)
    }

    func testAKeychainErrorNeverReplacesTheSavedKey() throws {
        let secrets = FlakySecrets()
        let saved = WireGuardDevices(secrets: secrets).setup
        secrets.failing = true
        let devices = WireGuardDevices(secrets: secrets)
        XCTAssertFalse(devices.loaded)
        XCTAssertNil(devices.connectReady(), "no device can connect before the setup is read")
        XCTAssertEqual(secrets.saves, 1, "nothing saved over the real setup")
        secrets.failing = false
        devices.load()
        XCTAssertTrue(devices.loaded)
        XCTAssertEqual(devices.setup.serverPrivateKey, saved.serverPrivateKey)
        XCTAssertNotNil(devices.connectReady())
    }

    func testASetupThatDoesntDecodeIsKeptUntilReset() {
        let secrets = InMemorySecrets()
        secrets.data = Data("from a newer version".utf8)
        let devices = WireGuardDevices(secrets: secrets)
        XCTAssertTrue(devices.needsReset)
        XCTAssertNil(devices.connectReady())
        XCTAssertEqual(secrets.data, Data("from a newer version".utf8), "not overwritten")
        devices.reset()
        XCTAssertTrue(devices.loaded)
        XCTAssertNotNil(devices.connectReady())
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup, devices.setup)
    }

    func testResetThatCantBeSavedLeavesTheSetupUnloadedUntilItCanBe() {
        let secrets = FlakySecrets()
        secrets.data = Data("from a newer version".utf8)
        let devices = WireGuardDevices(secrets: secrets)
        XCTAssertTrue(devices.needsReset)
        secrets.savesFail = true
        devices.reset()
        XCTAssertFalse(devices.loaded)
        XCTAssertFalse(devices.needsReset, "the failure is the Keychain's now, not the setup's")
        XCTAssertTrue(devices.loadError is WireGuardDevices.Unsaved)
        XCTAssertNil(devices.setup.ready, "no QR code for keys that aren't saved")
        XCTAssertNil(devices.connectReady())
        secrets.savesFail = false
        devices.reset()
        XCTAssertTrue(devices.loaded)
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.ready, devices.setup.ready)
    }

    /// A device that scanned a code that was never saved could never connect: the next launch makes another.
    func testANewSetupThatCantBeSavedHasNoQRCode() throws {
        let secrets = FlakySecrets()
        secrets.savesFail = true
        let devices = WireGuardDevices(secrets: secrets)
        XCTAssertFalse(devices.loaded)
        XCTAssertFalse(devices.needsReset)
        XCTAssertTrue(devices.loadError is WireGuardDevices.Unsaved, "its own reason, not a Keychain that can't be read")
        XCTAssertNil(devices.setup.ready)
        secrets.savesFail = false
        devices.load()
        XCTAssertTrue(devices.loaded)
        let ready = try XCTUnwrap(devices.setup.ready)
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.ready, ready, "saved")
    }

    func testAnUnsavedSetupSaysWhy() {
        XCTAssertEqual("\(WireGuardDevices.Unsaved(reason: KeychainSecrets.Failure(status: -34018)))",
                       "the new WireGuard keys can't be saved: Keychain error -34018")
    }

    func testAnOlderSetupWhoseReadyDeviceCantBeSavedKeepsItsDevicesButHasNoQRCode() throws {
        let secrets = FlakySecrets()
        var old = WireGuardSetup.new()
        _ = old.addPeer(name: "UTR")
        secrets.data = try JSONEncoder().encode(old) // no ready device
        secrets.savesFail = true
        let devices = WireGuardDevices(secrets: secrets)
        XCTAssertTrue(devices.loaded, "the devices it has still connect")
        XCTAssertEqual(devices.setup.peers.map(\.name), ["UTR"])
        XCTAssertNil(devices.setup.ready)
        XCTAssertNotNil(devices.readyError)
        XCTAssertFalse(devices.prepareReady(), "still can't be saved")
        XCTAssertNil(devices.setup.ready)
        secrets.savesFail = false
        XCTAssertTrue(devices.prepareReady())
        let ready = try XCTUnwrap(devices.setup.ready)
        XCTAssertNil(devices.readyError)
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.ready, ready, "saved")
        XCTAssertFalse(devices.prepareReady(), "there's one already")
    }

    /// With all 253 addresses taken there's no ready device, and removing one makes room for it.
    func testARemovalOnAFullSubnetMakesRoomForTheQRCode() throws {
        let secrets = InMemorySecrets()
        var full = WireGuardSetup.new()
        for i in 0..<253 { _ = full.addPeer(name: "d\(i)") }
        secrets.data = try JSONEncoder().encode(full)
        let devices = WireGuardDevices(secrets: secrets)
        XCTAssertNil(devices.setup.ready)
        XCTAssertNil(devices.readyError, "full isn't a failure")
        XCTAssertFalse(devices.prepareReady())
        devices.remove(devices.setup.peers[0].id)
        XCTAssertTrue(devices.prepareReady())
        XCTAssertEqual(devices.setup.ready?.address, "10.7.0.2")
    }

    func testNothingIsRemovedBeforeTheSetupIsLoaded() {
        let secrets = FlakySecrets()
        let devices = WireGuardDevices(secrets: secrets)
        let peer = devices.connectReady()!
        secrets.failing = true
        let locked = WireGuardDevices(secrets: secrets)
        XCTAssertFalse(locked.remove(peer.id))
        secrets.failing = false
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.peers.map(\.id), [peer.id], "still saved")
    }

    /// It would come back with the next launch, so it stays now too, like a rename that can't be saved.
    func testARemovalThatCantBeSavedKeepsTheDevice() {
        let secrets = FlakySecrets()
        let devices = WireGuardDevices(secrets: secrets)
        let peer = devices.connectReady()!
        secrets.savesFail = true
        XCTAssertFalse(devices.remove(peer.id))
        XCTAssertEqual(devices.setup.peers.map(\.id), [peer.id])
    }
}

/// Uses a Keychain item of its own, so the app's real setup is never touched. Where the Mac's
/// Keychain refuses a process without entitlements, the tests skip with the status.
final class KeychainSecretsTests: XCTestCase {
    private var service = ""
    private var secrets: KeychainSecrets!

    override func setUpWithError() throws {
        service = "tether.wireguard.tests.\(UUID().uuidString)"
        secrets = KeychainSecrets(service: service)
        // Reading can work where saving can't: a CI runner can be a background service with no
        // unlocked login keychain, and saving there fails with errSecInteractionNotAllowed
        // (-25308). So try both once, and skip where this Keychain isn't usable.
        do {
            _ = try secrets.load()
            try secrets.save(Data("probe".utf8))
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        } catch let failure as KeychainSecrets.Failure {
            throw XCTSkip("the Keychain refuses this process: \(failure)")
        }
    }

    override func tearDown() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }

    func testNothingSavedLoadsAsNil() throws {
        XCTAssertNil(try secrets.load())
    }

    func testWhatWasSavedComesBack() throws {
        try secrets.save(Data("setup".utf8))
        XCTAssertEqual(try secrets.load(), Data("setup".utf8))
        XCTAssertEqual(try KeychainSecrets(service: service).load(), Data("setup".utf8), "a new instance sees the same item")
    }

    func testSavingAgainReplacesTheItem() throws {
        try secrets.save(Data("first".utf8))
        try secrets.save(Data("second".utf8))
        XCTAssertEqual(try secrets.load(), Data("second".utf8))
    }

    func testAnotherServiceDoesNotSeeTheItem() throws {
        try secrets.save(Data("setup".utf8))
        XCTAssertNil(try KeychainSecrets(service: service + ".other").load())
    }

    func testAFailureCarriesTheKeychainStatus() {
        XCTAssertEqual(KeychainSecrets.Failure(status: -25308).description, "Keychain error -25308")
    }

    func testTheStoreKeepsItsSetupInTheKeychain() throws {
        let first = WireGuardDevices(secrets: secrets)
        try XCTSkipUnless(first.loaded, "the Keychain refuses this process")
        _ = first.connectReady()
        let second = WireGuardDevices(secrets: KeychainSecrets(service: service))
        XCTAssertEqual(second.setup, first.setup)
        XCTAssertEqual(second.setup.peers.map(\.name), ["Device"])
    }
}

final class TrafficTotalsTests: XCTestCase {
    func testCarriedTotalsNeverGoBackwards() {
        var carried = CarriedTotals()
        let run1 = TrafficTotals(bytesUp: 10, bytesDown: 100)
        XCTAssertEqual(carried.apply(to: run1), run1)
        carried.absorb(run1) // the server restarts and its counters start again from zero
        XCTAssertEqual(carried.apply(to: TrafficTotals(bytesUp: 1, bytesDown: 5)), TrafficTotals(bytesUp: 11, bytesDown: 105))
        XCTAssertEqual(carried.apply(to: TrafficTotals()), run1, "a stopped server still counts what came before")
    }
}

final class FlakySecrets: SecretStore {
    var failing = false
    var savesFail = false
    var saves = 0
    var data: Data?
    struct Locked: Error {}
    func load() throws -> Data? {
        if failing { throw Locked() }
        return data
    }
    func save(_ data: Data) throws {
        if savesFail { throw Locked() }
        saves += 1
        self.data = data
    }
}

extension WireGuardDevices {
    /// What a device scanning the QR code does: it connects with the ready device, which is claimed.
    func connectReady() -> WireGuardSetup.Peer? {
        guard let ready = setup.ready, claimReady(address: ready.address) else { return nil }
        return setup.peers.last
    }
}
