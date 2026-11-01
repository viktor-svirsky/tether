import XCTest
@testable import TetherCore

/// What Tether tells in notifications, round by round, with a fake clock and its own UserDefaults.
final class NotifierTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let ipad = WireGuardSetup.Peer(name: "iPad", publicKey: Data(), address: "10.7.0.2")
    private let pc = WireGuardSetup.Peer(name: "Windows PC", publicKey: Data(), address: "10.7.0.3")
    private let router = WireGuardSetup.Peer(name: "Router", publicKey: Data(), address: "10.7.0.4")
    private var defaults: UserDefaults!
    private var notifier: Notifier!
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "NotifierTests")!
        defaults.removePersistentDomain(forName: "NotifierTests")
        notifier = Notifier(defaults: defaults, calendar: utc)
    }

    private func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

    /// One round in the background while sharing, unless said otherwise. Returns what it would post, as "title: body".
    @discardableResult
    private func round(at m: Double, _ connected: Set<String>, onScreen: Bool = false, hotspot: Bool = true, sharing: Bool = true,
                       devices: [WireGuardSetup.Peer]? = nil, expires: Date? = nil) -> [String] {
        notifier.check(Notifier.Round(now: minutes(m), onScreen: onScreen, hotspot: hotspot, sharing: sharing,
                                      devices: devices ?? [ipad, pc, router], connected: connected, expires: expires))
            .map { "\($0.title): \($0.body)" }
    }

    // MARK: Devices

    func testADeviceThatConnectsIsToldByName() {
        round(at: 0, [])
        XCTAssertEqual(round(at: 0.25, ["10.7.0.2"]), ["iPad connected: It's using this iPhone's data now."])
        XCTAssertEqual(round(at: 0.5, ["10.7.0.2"]), [], "told once")
    }

    func testADeviceThatLeavesIsToldOnlyOnceItsBeenGoneThreeMinutes() {
        round(at: 0, ["10.7.0.2"])
        XCTAssertEqual(round(at: 1, []), [])
        XCTAssertEqual(round(at: 3.9, []), [], "a laptop that sleeps for a moment")
        XCTAssertEqual(round(at: 6, []), ["iPad disconnected: It left a few minutes ago."])
        XCTAssertEqual(round(at: 7, []), [])
    }

    func testADeviceThatComesBackBeforeThreeMinutesIsntTold() {
        round(at: 0, ["10.7.0.2"])
        round(at: 1, [])
        XCTAssertEqual(round(at: 2.5, ["10.7.0.2"]), [])
        round(at: 3, [])
        XCTAssertEqual(round(at: 5.5, []), [], "the 3 minutes start again")
        XCTAssertEqual(round(at: 6.5, []), ["iPad disconnected: It left a few minutes ago."])
    }

    /// A device that comes and goes posts at most once in 5 minutes. A change in between is told when the 5 minutes are up, if it still holds.
    func testADeviceThatFlapsPostsOnceInFiveMinutes() {
        round(at: 0, [])
        XCTAssertEqual(round(at: 0.5, ["10.7.0.2"]).count, 1)
        round(at: 1, [])
        XCTAssertEqual(round(at: 4.5, []), [], "gone 3 minutes, but it posted 4 minutes ago")
        XCTAssertEqual(round(at: 5.5, []), ["iPad disconnected: It left a few minutes ago."])
        XCTAssertEqual(round(at: 6, ["10.7.0.2"]), [], "back, but it posted half a minute ago")
        round(at: 7, [])
        XCTAssertEqual(round(at: 10.5, []), [], "gone again before the 5 minutes were up, so nothing changed")
    }

    func testEachDeviceHasItsOwnQuietTime() {
        round(at: 0, [])
        XCTAssertEqual(round(at: 0.5, ["10.7.0.2"]).count, 1)
        XCTAssertEqual(round(at: 0.75, ["10.7.0.2", "10.7.0.3"]), ["Windows PC connected: It's using this iPhone's data now."])
    }

    func testTwoDevicesInOneRoundPostTwice() {
        round(at: 0, [])
        XCTAssertEqual(round(at: 0.25, ["10.7.0.2", "10.7.0.3"]).count, 2)
    }

    func testANoticeReplacesTheLastOneForTheSameDevice() {
        func check(at m: Double, _ connected: Set<String>) -> [Notice] {
            notifier.check(.init(now: minutes(m), onScreen: false, hotspot: true, sharing: true, devices: [ipad], connected: connected))
        }
        _ = check(at: 0, [])
        let connected = check(at: 1, ["10.7.0.2"])
        _ = check(at: 5, [])
        let left = check(at: 10, [])
        XCTAssertEqual(connected.map(\.id), left.map(\.id))
        XCTAssertEqual(connected.map(\.kind), [.connected])
        XCTAssertEqual(left.map(\.kind), [.disconnected])
    }

    func testARenamedDeviceIsToldByItsNewName() {
        round(at: 0, [])
        var renamed = ipad
        renamed.name = "Kitchen iPad"
        XCTAssertEqual(round(at: 1, ["10.7.0.2"], devices: [renamed]), ["Kitchen iPad connected: It's using this iPhone's data now."])
    }

    /// The ready device's address is connected before it's listed. Only listed devices have a name to tell.
    func testAnAddressThatIsntADeviceIsntTold() {
        round(at: 0, [])
        XCTAssertEqual(round(at: 1, ["10.7.0.9"]), [])
    }

    // MARK: On screen

    func testNothingIsToldOnScreen() {
        round(at: 0, [], onScreen: true)
        XCTAssertEqual(round(at: 1, ["10.7.0.2"], onScreen: true), [])
        XCTAssertEqual(round(at: 10, [], onScreen: true), [])
    }

    /// The screen showed it, so leaving the screen doesn't tell it again.
    func testWhatTheScreenShowedIsntToldAfterLeavingIt() {
        round(at: 0, ["10.7.0.2"], onScreen: true)
        XCTAssertEqual(round(at: 0.25, ["10.7.0.2"]), [])
        round(at: 1, [], onScreen: true) // Not connected on screen
        XCTAssertEqual(round(at: 10, []), [])
    }

    /// The moment to ask for permission: iOS shows the question only while Tether is on screen.
    func testOnScreenItSaysWhenItWouldHaveTold() {
        round(at: 0, [], onScreen: true)
        XCTAssertFalse(notifier.wouldTell)
        round(at: 1, ["10.7.0.2"], onScreen: true)
        XCTAssertTrue(notifier.wouldTell, "a device connected")
        round(at: 1.25, ["10.7.0.2"], onScreen: true)
        XCTAssertFalse(notifier.wouldTell, "only the round it happened in")
        round(at: 2, ["10.7.0.2"])
        round(at: 2.25, [])
        XCTAssertFalse(notifier.wouldTell, "not in the background, which posts instead")
    }

    /// A device added with the QR code is listed in the same round it's first seen connected.
    func testADeviceAddedOnScreenWouldHaveBeenTold() {
        round(at: 0, ["10.7.0.2"], onScreen: true, devices: [ipad])
        round(at: 1, ["10.7.0.2"], onScreen: true, devices: [ipad, pc])
        XCTAssertFalse(notifier.wouldTell, "listed but not connected")
        round(at: 2, ["10.7.0.2", "10.7.0.4"], onScreen: true, devices: [ipad, pc, router])
        XCTAssertTrue(notifier.wouldTell, "listed and connected at once")
    }

    func testASwitchedOffKindWouldTellNothing() {
        defaults.set(false, forKey: NoticeKind.connected.key)
        round(at: 0, [], onScreen: true)
        round(at: 1, ["10.7.0.2"], onScreen: true)
        XCTAssertFalse(notifier.wouldTell)
    }

    func testAChangeAfterLeavingTheScreenIsTold() {
        round(at: 0, ["10.7.0.2"], onScreen: true)
        round(at: 1, ["10.7.0.2"])
        XCTAssertEqual(round(at: 2, []), [])
        XCTAssertEqual(round(at: 5, []), ["iPad disconnected: It left a few minutes ago."])
    }

    // MARK: Switches

    func testEveryKindIsOnByDefault() {
        XCTAssertTrue(NoticeKind.allCases.allSatisfy { $0.isOn(in: defaults) })
    }

    func testASwitchedOffKindPostsNothing() {
        defaults.set(false, forKey: NoticeKind.connected.key)
        round(at: 0, [])
        XCTAssertEqual(round(at: 1, ["10.7.0.2"]), [])
        round(at: 2, [])
        XCTAssertEqual(round(at: 5, []), ["iPad disconnected: It left a few minutes ago."],
                       "a switched-off notice starts no quiet time, and the device still counts as connected")
    }

    func testTheSwitchesAreSavedUnderTheirOwnKeys() {
        XCTAssertEqual(NoticeKind.allCases.map(\.key), ["notify.connected", "notify.disconnected", "notify.sharingStopped", "notify.expiring"])
    }

    // MARK: Sharing stops

    /// The hotspot's network also goes when the last device leaves it, so Tether can't tell the hotspot
    /// turned off from a laptop that left. Each device that was connected is told as disconnected,
    /// which is true either way, as long after as one device leaving is.
    func testWhenTheHotspotGoesEachDeviceIsToldAsDisconnected() {
        round(at: 0, ["10.7.0.2", "10.7.0.3"])
        XCTAssertEqual(round(at: 1, [], hotspot: false, sharing: false), [])
        XCTAssertEqual(round(at: 3.9, [], hotspot: false, sharing: false), [])
        XCTAssertEqual(round(at: 4, [], hotspot: false, sharing: false),
                       ["iPad disconnected: It left a few minutes ago.", "Windows PC disconnected: It left a few minutes ago."])
        XCTAssertEqual(round(at: 5, [], hotspot: false, sharing: false), [], "told once")
        XCTAssertEqual(round(at: 20, [], hotspot: false, sharing: false), [])
    }

    func testAHotspotThatComesBackWithinThreeMinutesIsntTold() {
        round(at: 0, ["10.7.0.2"])
        round(at: 0.25, [], hotspot: false, sharing: false)
        XCTAssertEqual(round(at: 2.75, [], hotspot: false, sharing: false), [])
        XCTAssertEqual(round(at: 3, []), [], "the device is still within its 3 minutes")
        XCTAssertEqual(round(at: 3.5, ["10.7.0.2"]), [], "it never left as far as the owner knows")
    }

    func testSharingThatStopsWithNobodyConnectedIsntTold() {
        round(at: 0, [])
        round(at: 1, [], hotspot: false, sharing: false)
        XCTAssertEqual(round(at: 5, [], hotspot: false, sharing: false), [])
    }

    func testAWireGuardProblemSaysToOpenTether() {
        round(at: 0, ["10.7.0.2"])
        round(at: 1, [], sharing: false)
        XCTAssertEqual(round(at: 2, [], sharing: false),
                       ["Sharing stopped: WireGuard stopped while iPad was connected. Open Tether to see why."])
    }

    func testThreeDevicesAreCounted() {
        round(at: 0, ["10.7.0.2", "10.7.0.3", "10.7.0.4"])
        round(at: 1, [], sharing: false)
        XCTAssertEqual(round(at: 2, [], sharing: false),
                       ["Sharing stopped: WireGuard stopped while 3 devices were connected. Open Tether to see why."])
    }

    /// One that left 2 minutes ago still counts: the owner was never told it left.
    func testADeviceInItsThreeMinutesCountsAsConnected() {
        round(at: 0, ["10.7.0.2", "10.7.0.3"])
        round(at: 1, ["10.7.0.2"])
        round(at: 3, [], hotspot: false, sharing: false)
        XCTAssertEqual(round(at: 6, [], hotspot: false, sharing: false),
                       ["iPad disconnected: It left a few minutes ago.", "Windows PC disconnected: It left a few minutes ago."])
    }

    /// Its disconnected notice starts its quiet time like any other.
    func testAfterAStopEachDeviceThatComesBackIsTold() {
        round(at: 0, ["10.7.0.2"])
        round(at: 1, [], hotspot: false, sharing: false)
        round(at: 4, [], hotspot: false, sharing: false)
        XCTAssertEqual(round(at: 8, ["10.7.0.2"]), [], "within 5 minutes of its last notice")
        XCTAssertEqual(round(at: 9, ["10.7.0.2"]), ["iPad connected: It's using this iPhone's data now."])
    }

    func testAStopOnScreenIsntTold() {
        round(at: 0, ["10.7.0.2"])
        round(at: 1, [], onScreen: true, hotspot: false, sharing: false)
        XCTAssertTrue(notifier.wouldTell)
        XCTAssertEqual(round(at: 5, [], onScreen: true, hotspot: false, sharing: false), [])
        XCTAssertEqual(round(at: 6, [], hotspot: false, sharing: false), [])
    }

    /// The screen showed it stopped, so leaving the screen before the wait is up tells nothing.
    func testAStopSeenOnScreenIsntToldAfterLeaving() {
        round(at: 0, ["10.7.0.2"])
        round(at: 0.25, [], hotspot: false, sharing: false)
        round(at: 0.5, [], onScreen: true, hotspot: false, sharing: false)
        XCTAssertEqual(round(at: 0.75, [], hotspot: false, sharing: false), [])
        XCTAssertEqual(round(at: 5, [], hotspot: false, sharing: false), [])
    }

    func testAStopWithItsSwitchOffIsntTold() {
        defaults.set(false, forKey: NoticeKind.sharingStopped.key)
        round(at: 0, ["10.7.0.2"])
        round(at: 1, [], sharing: false)
        XCTAssertEqual(round(at: 5, [], sharing: false), [])
        XCTAssertEqual(round(at: 20, [], sharing: false), [], "and the device isn't told as gone instead")
    }

    func testAHotspotThatGoesWithDisconnectedSwitchedOffIsntTold() {
        defaults.set(false, forKey: NoticeKind.disconnected.key)
        round(at: 0, ["10.7.0.2"])
        round(at: 1, [], hotspot: false, sharing: false)
        XCTAssertEqual(round(at: 5, [], hotspot: false, sharing: false), [])
    }

    // MARK: The build expiring

    private func day(_ d: Int, _ hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour))!
    }

    @discardableResult
    private func expiryRound(at now: Date, expires: Date, onScreen: Bool = false) -> [String] {
        notifier.check(Notifier.Round(now: now, onScreen: onScreen, hotspot: false, sharing: false, devices: [], connected: [], expires: expires))
            .map { "\($0.title): \($0.body)" }
    }

    func testTheBuildExpiringIsToldOnceADay() {
        let expires = day(26, 9)
        XCTAssertEqual(expiryRound(at: day(22), expires: expires), [], "more than 3 days left")
        XCTAssertEqual(expiryRound(at: day(23, 10), expires: expires),
                       ["Tether stops opening in 3 days: Refresh it in SideStore or AltStore before then."])
        XCTAssertEqual(expiryRound(at: day(23, 22), expires: expires), [], "once a day")
        XCTAssertEqual(expiryRound(at: day(25, 1), expires: expires),
                       ["Tether stops opening tomorrow: Refresh it in SideStore or AltStore before then."])
        XCTAssertEqual(expiryRound(at: day(26, 7), expires: expires),
                       ["Tether stops opening today: Refresh it in SideStore or AltStore before then."])
    }

    func testTheDayToldIsSavedForTheNextLaunch() {
        expiryRound(at: day(24), expires: day(26))
        notifier = Notifier(defaults: defaults, calendar: utc)
        XCTAssertEqual(expiryRound(at: day(24, 20), expires: day(26)), [])
    }

    func testADayTheScreenShowedTheWarningIsntToldAgain() {
        XCTAssertEqual(expiryRound(at: day(24, 9), expires: day(26), onScreen: true), [])
        XCTAssertEqual(expiryRound(at: day(24, 20), expires: day(26)), [])
        XCTAssertEqual(expiryRound(at: day(25, 9), expires: day(26)).count, 1)
    }

    func testNoExpiryNoticeWithoutAProfileOrWithItsSwitchOff() {
        XCTAssertEqual(notifier.check(.init(now: day(24), onScreen: false, hotspot: false, sharing: false, devices: [], connected: [])), [])
        defaults.set(false, forKey: NoticeKind.expiring.key)
        XCTAssertEqual(expiryRound(at: day(24), expires: day(26)), [])
        defaults.set(true, forKey: NoticeKind.expiring.key)
        XCTAssertEqual(expiryRound(at: day(24, 13), expires: day(26)).count, 1, "turned on later the same day")
    }
}

/// Asking for permission and posting, with a fake notification center.
@MainActor
final class NoticePosterTests: XCTestCase {
    private let notice = Notice(kind: .connected, id: "device.1", title: "iPad connected", body: "")

    func testAllowedPostsWithoutAsking() async {
        let center = FakeNoticeCenter(.allowed)
        await NoticePoster(center: center).post([notice])
        XCTAssertEqual(center.asked, 0)
        XCTAssertEqual(center.added, [notice])
    }

    /// Posting happens in the background, where iOS can't show the question.
    func testNotAskedYetPostsNothingAndDoesntAsk() async {
        let center = FakeNoticeCenter(.notAsked, answer: true)
        await NoticePoster(center: center).post([notice])
        XCTAssertEqual(center.asked, 0)
        XCTAssertEqual(center.added, [])
    }

    func testDeniedPostsNothing() async {
        let center = FakeNoticeCenter(.denied)
        await NoticePoster(center: center).post([notice])
        XCTAssertEqual(center.added, [])
    }

    func testAskingOnScreenAsksOnceThenPosts() async {
        let center = FakeNoticeCenter(.notAsked, answer: true)
        let poster = NoticePoster(center: center)
        await poster.askIfNotAsked()
        await poster.askIfNotAsked()
        XCTAssertEqual(center.asked, 1)
        await poster.post([notice])
        XCTAssertEqual(center.added, [notice])
    }

    /// After a no iOS never shows the question again, and Tether doesn't try.
    func testAfterANoItNeverAsksOrPostsAgain() async {
        let center = FakeNoticeCenter(.notAsked, answer: false)
        let poster = NoticePoster(center: center)
        await poster.askIfNotAsked()
        await poster.askIfNotAsked()
        await poster.post([notice])
        XCTAssertEqual(center.asked, 1)
        XCTAssertEqual(center.added, [])
    }

    func testAllowedOrDeniedIsntAskedAgain() async {
        for state in [NoticePermission.allowed, .denied] {
            let center = FakeNoticeCenter(state)
            await NoticePoster(center: center).askIfNotAsked()
            XCTAssertEqual(center.asked, 0, "\(state)")
        }
    }

    /// Two rounds in a row that would tell something while the question is up ask once.
    func testRoundsWhileAskingShareOneQuestion() async {
        let center = FakeNoticeCenter(.notAsked, answer: true)
        center.holdAnswer = true
        let poster = NoticePoster(center: center)
        async let first: Void = poster.askIfNotAsked()
        async let second: Void = poster.askIfNotAsked()
        while center.asked == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() } // the second one reaches the question too
        center.release()
        _ = await (first, second)
        XCTAssertEqual(center.asked, 1)
    }

    func testNothingToTellChecksNothing() async {
        let center = FakeNoticeCenter(.allowed)
        await NoticePoster(center: center).post([])
        XCTAssertEqual(center.checked, 0)
    }
}

/// The system's notification center, with the permission a test sets and the user's answer to the question.
@MainActor
final class FakeNoticeCenter: NoticeCenter {
    private var state: NoticePermission
    private let answer: Bool
    /// Keeps the question up until `release()`.
    var holdAnswer = false
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var checked = 0
    private(set) var asked = 0
    private(set) var added: [Notice] = []

    init(_ state: NoticePermission, answer: Bool = false) {
        self.state = state
        self.answer = answer
    }

    func permission() async -> NoticePermission {
        checked += 1
        return state
    }

    func ask() async -> Bool {
        asked += 1
        if holdAnswer { await withCheckedContinuation { waiting = $0 } }
        state = answer ? .allowed : .denied
        return answer
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }

    func add(_ notice: Notice) async {
        added.append(notice)
    }
}
