import XCTest
@testable import TetherCore

/// The local networks setting (#230): blocked for a new Tether, allowed for one updated from before
/// the setting, and kept once saved.
final class LocalNetworksTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "LocalNetworksTests")
        defaults.removePersistentDomain(forName: "LocalNetworksTests")
    }

    private struct Locked: Error {}

    func testANewTetherBlocksThem() {
        LocalNetworks.settle(in: defaults, introduced: false, savedSetup: { nil })
        XCTAssertEqual(defaults.object(forKey: LocalNetworks.key) as? Bool, false)
    }

    func testATetherSetUpBeforeTheSettingKeepsThem() {
        LocalNetworks.settle(in: defaults, introduced: true, savedSetup: { throw Locked() })
        XCTAssertTrue(LocalNetworks.allowed(in: defaults), "the screen's mark is enough, Keychain or not")
        defaults.removePersistentDomain(forName: "LocalNetworksTests")
        LocalNetworks.settle(in: defaults, introduced: false, savedSetup: { Data([1]) })
        XCTAssertTrue(LocalNetworks.allowed(in: defaults), "a saved setup from before 1.6 counts too")
    }

    /// A locked Keychain decides nothing, so an update from before 1.6 isn't saved as blocked by a
    /// launch in the background. The next call, once it can be read, decides.
    func testALockedKeychainDecidesLater() {
        LocalNetworks.settle(in: defaults, introduced: false, savedSetup: { throw Locked() })
        XCTAssertNil(defaults.object(forKey: LocalNetworks.key))
        LocalNetworks.settle(in: defaults, introduced: false, savedSetup: { Data([1]) })
        XCTAssertTrue(LocalNetworks.allowed(in: defaults))
    }

    func testTheOwnersChoiceStays() {
        defaults.set(true, forKey: LocalNetworks.key)
        LocalNetworks.settle(in: defaults, introduced: false, savedSetup: { nil })
        XCTAssertTrue(LocalNetworks.allowed(in: defaults), "settle doesn't overwrite a saved choice")
        defaults.set(false, forKey: LocalNetworks.key)
        LocalNetworks.settle(in: defaults, introduced: true, savedSetup: { Data([1]) })
        XCTAssertFalse(LocalNetworks.allowed(in: defaults))
    }
}
