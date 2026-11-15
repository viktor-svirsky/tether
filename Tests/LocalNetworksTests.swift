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

    func testANewTetherBlocksThem() {
        LocalNetworks.settle(in: defaults, wasSetUp: false)
        XCTAssertFalse(LocalNetworks.allowed(in: defaults))
    }

    func testATetherSetUpBeforeTheSettingKeepsThem() {
        LocalNetworks.settle(in: defaults, wasSetUp: true)
        XCTAssertTrue(LocalNetworks.allowed(in: defaults))
    }

    func testTheOwnersChoiceStays() {
        defaults.set(true, forKey: LocalNetworks.key)
        LocalNetworks.settle(in: defaults, wasSetUp: false)
        XCTAssertTrue(LocalNetworks.allowed(in: defaults), "settle doesn't overwrite a saved choice")
        defaults.set(false, forKey: LocalNetworks.key)
        LocalNetworks.settle(in: defaults, wasSetUp: true)
        XCTAssertFalse(LocalNetworks.allowed(in: defaults))
    }
}
