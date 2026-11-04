import XCTest
@testable import TetherCore

/// UsageLedger: what each device used this month and last, and when it last connected, from the
/// server's counters, with a fixed calendar so a month starts at a known moment.
final class DataUsageTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private let ipad = WireGuardSetup.Peer(name: "iPad", publicKey: Data(repeating: 1, count: 32), address: "10.7.0.2")
    private let pc = WireGuardSetup.Peer(name: "Windows PC", publicKey: Data(repeating: 2, count: 32), address: "10.7.0.3")

    /// Local time in New York.
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func snapshot(_ peers: [String: PeerStats]) -> ServerSnapshot {
        ServerSnapshot(peers: peers)
    }

    private func used(_ up: UInt64, _ down: UInt64, connected: Bool = false, handshake: Date? = nil) -> PeerStats {
        PeerStats(traffic: TrafficTotals(bytesUp: up, bytesDown: down), connected: connected, lastHandshake: handshake)
    }

    func testEachReadAddsWhatTheCountersMovedSince() {
        var ledger = UsageLedger()
        let now = date(2026, 10, 17)
        XCTAssertTrue(ledger.record(snapshot([ipad.address: used(10, 100)]), peers: [ipad], now: now, calendar: calendar),
                      "a device first seen counts from 0: the server's counters start with the app")
        ledger.record(snapshot([ipad.address: used(15, 300)]), peers: [ipad], now: now, calendar: calendar)
        XCTAssertEqual(ledger.usage(of: ipad.id, now: now, calendar: calendar).thisMonth, TrafficTotals(bytesUp: 15, bytesDown: 300))
    }

    func testAnIdleDeviceChangesNothing() {
        var ledger = UsageLedger()
        let now = date(2026, 10, 17)
        ledger.record(snapshot([ipad.address: used(10, 100)]), peers: [ipad], now: now, calendar: calendar)
        XCTAssertFalse(ledger.record(snapshot([ipad.address: used(10, 100)]), peers: [ipad], now: now, calendar: calendar),
                       "nothing to save")
    }

    func testACounterThatGoesDownAddsNothingAndCountsOnFromThere() {
        var ledger = UsageLedger()
        let now = date(2026, 10, 17)
        ledger.record(snapshot([ipad.address: used(10, 100)]), peers: [ipad], now: now, calendar: calendar)
        ledger.record(snapshot([ipad.address: used(1, 1)]), peers: [ipad], now: now, calendar: calendar)
        ledger.record(snapshot([ipad.address: used(2, 5)]), peers: [ipad], now: now, calendar: calendar)
        XCTAssertEqual(ledger.usage(of: ipad.id, now: now, calendar: calendar).thisMonth, TrafficTotals(bytesUp: 11, bytesDown: 104))
    }

    func testEachDeviceCountsByItsOwnAddress() {
        var ledger = UsageLedger()
        let now = date(2026, 10, 17)
        ledger.record(snapshot([ipad.address: used(1, 2), pc.address: used(30, 40)]), peers: [ipad, pc], now: now, calendar: calendar)
        XCTAssertEqual(ledger.usage(of: ipad.id, now: now, calendar: calendar).thisMonth, TrafficTotals(bytesUp: 1, bytesDown: 2))
        XCTAssertEqual(ledger.usage(of: pc.id, now: now, calendar: calendar).thisMonth, TrafficTotals(bytesUp: 30, bytesDown: 40))
    }

    func testANewMonthStartsAtLocalMidnightOnTheFirst() {
        var ledger = UsageLedger()
        ledger.record(snapshot([ipad.address: used(0, 100)]), peers: [ipad], now: date(2026, 10, 31, 23, 59), calendar: calendar)
        // What moved across midnight goes to the month it's read in.
        ledger.record(snapshot([ipad.address: used(0, 130)]), peers: [ipad], now: date(2026, 11, 1, 0, 1), calendar: calendar)
        let usage = ledger.usage(of: ipad.id, now: date(2026, 11, 1, 0, 1), calendar: calendar)
        XCTAssertEqual(usage.thisMonth, TrafficTotals(bytesDown: 30))
        XCTAssertEqual(usage.lastMonth, TrafficTotals(bytesDown: 100))
        // Still October in New York, already November in UTC.
        let late = date(2026, 10, 31, 22)
        XCTAssertEqual(ledger.usage(of: ipad.id, now: late, calendar: calendar).thisMonth, TrafficTotals(bytesDown: 100))
    }

    func testAMonthWithNothingReadStartsAtZero() {
        var ledger = UsageLedger()
        ledger.record(snapshot([ipad.address: used(0, 100)]), peers: [ipad], now: date(2026, 10, 17), calendar: calendar)
        let usage = ledger.usage(of: ipad.id, now: date(2026, 11, 2), calendar: calendar)
        XCTAssertEqual(usage.thisMonth, TrafficTotals())
        XCTAssertEqual(usage.lastMonth, TrafficTotals(bytesDown: 100))
        XCTAssertEqual(ledger.usage(of: ipad.id, now: date(2026, 12, 2), calendar: calendar).lastMonth, TrafficTotals(),
                       "October is two months back by December")
    }

    func testOnlyThisMonthAndLastAreKept() throws {
        var ledger = UsageLedger()
        ledger.record(snapshot([ipad.address: used(0, 100)]), peers: [ipad], now: date(2026, 9, 10), calendar: calendar)
        ledger.record(snapshot([ipad.address: used(0, 300)]), peers: [ipad], now: date(2026, 10, 10), calendar: calendar)
        ledger.record(snapshot([ipad.address: used(0, 600)]), peers: [ipad], now: date(2026, 11, 10), calendar: calendar)
        let saved = try UsageLedger(saved: ledger.saved())
        XCTAssertEqual(saved.usage(of: ipad.id, now: date(2026, 10, 10), calendar: calendar).lastMonth, TrafficTotals(),
                       "September is gone from what's saved")
        XCTAssertEqual(saved.usage(of: ipad.id, now: date(2026, 11, 10), calendar: calendar).lastMonth, TrafficTotals(bytesDown: 200))
    }

    func testAClockSetBackAMonthLosesNothing() {
        var ledger = UsageLedger()
        ledger.record(snapshot([ipad.address: used(0, 100)]), peers: [ipad], now: date(2026, 11, 2), calendar: calendar)
        ledger.record(snapshot([ipad.address: used(0, 110)]), peers: [ipad], now: date(2026, 10, 2), calendar: calendar)
        ledger.record(snapshot([ipad.address: used(0, 130)]), peers: [ipad], now: date(2026, 11, 3), calendar: calendar)
        XCTAssertEqual(ledger.usage(of: ipad.id, now: date(2026, 11, 3), calendar: calendar).thisMonth, TrafficTotals(bytesDown: 120))
        XCTAssertEqual(ledger.usage(of: ipad.id, now: date(2026, 11, 3), calendar: calendar).lastMonth, TrafficTotals(bytesDown: 10),
                       "what moved while the clock said October")
    }

    func testAConnectedDeviceThatSendsNothingChangesOnceAMinute() {
        var ledger = UsageLedger()
        ledger.record(snapshot([ipad.address: used(0, 0, connected: true)]), peers: [ipad], now: date(2026, 10, 17, 10, 0), calendar: calendar)
        XCTAssertFalse(ledger.record(snapshot([ipad.address: used(0, 0, connected: true)]), peers: [ipad],
                                     now: date(2026, 10, 17, 10, 0).addingTimeInterval(30), calendar: calendar))
        XCTAssertTrue(ledger.record(snapshot([ipad.address: used(0, 0, connected: true)]), peers: [ipad],
                                    now: date(2026, 10, 17, 10, 1), calendar: calendar))
    }

    func testADeviceThatsNoLongerListedIsForgotten() throws {
        var ledger = UsageLedger()
        let now = date(2026, 10, 17)
        ledger.record(snapshot([ipad.address: used(1, 2), pc.address: used(3, 4)]), peers: [ipad, pc], now: now, calendar: calendar)
        XCTAssertTrue(ledger.record(snapshot([ipad.address: used(1, 2)]), peers: [ipad], now: now, calendar: calendar))
        XCTAssertEqual(try UsageLedger(saved: ledger.saved()).usage(of: pc.id, now: now, calendar: calendar), DeviceUsage())
    }

    func testADeviceNotListedYetIsNotCounted() {
        var ledger = UsageLedger()
        let now = date(2026, 10, 17)
        // The ready device, behind the QR code, isn't listed until it's claimed.
        ledger.record(snapshot([pc.address: used(5, 50, connected: true)]), peers: [ipad], now: now, calendar: calendar)
        XCTAssertEqual(ledger.usage(of: pc.id, now: now, calendar: calendar), DeviceUsage())
        // Claimed: it counts from 0 in this run, so the round it was claimed in is counted too.
        ledger.record(snapshot([pc.address: used(6, 60, connected: true)]), peers: [ipad, pc], now: now, calendar: calendar)
        XCTAssertEqual(ledger.usage(of: pc.id, now: now, calendar: calendar).thisMonth, TrafficTotals(bytesUp: 6, bytesDown: 60))
    }

    func testLastConnectedIsNowWhileConnectedAndTheHandshakeAfter() {
        var ledger = UsageLedger()
        let at10 = date(2026, 10, 17, 10)
        ledger.record(snapshot([ipad.address: used(0, 0, connected: true, handshake: date(2026, 10, 17, 9, 58))]),
                      peers: [ipad], now: at10.addingTimeInterval(42), calendar: calendar)
        XCTAssertEqual(ledger.usage(of: ipad.id, now: at10, calendar: calendar).lastConnected, at10,
                       "handshakes come every two minutes, so the read's own time is closer, to the minute")
        // Gone: an older handshake doesn't move it back.
        ledger.record(snapshot([ipad.address: used(0, 0, handshake: date(2026, 10, 17, 9, 58))]),
                      peers: [ipad], now: date(2026, 10, 17, 11), calendar: calendar)
        XCTAssertEqual(ledger.usage(of: ipad.id, now: at10, calendar: calendar).lastConnected, at10)
        // A handshake later than that, read while it isn't connected any more.
        let later = date(2026, 10, 17, 10, 30)
        ledger.record(snapshot([ipad.address: used(0, 0, handshake: later)]), peers: [ipad], now: date(2026, 10, 17, 11), calendar: calendar)
        XCTAssertEqual(ledger.usage(of: ipad.id, now: at10, calendar: calendar).lastConnected, later)
    }

    func testANeverConnectedDeviceHasNoLastConnection() {
        var ledger = UsageLedger()
        let now = date(2026, 10, 17)
        ledger.record(snapshot([pc.address: used(0, 0)]), peers: [pc], now: now, calendar: calendar)
        XCTAssertNil(ledger.usage(of: pc.id, now: now, calendar: calendar).lastConnected)
    }

    func testWhatsSavedComesBackAndCountsOnFromZero() throws {
        var ledger = UsageLedger()
        let now = date(2026, 10, 17)
        ledger.record(snapshot([ipad.address: used(10, 100, connected: true)]), peers: [ipad], now: now, calendar: calendar)
        var relaunched = try UsageLedger(saved: ledger.saved())
        XCTAssertEqual(relaunched.usage(of: ipad.id, now: now, calendar: calendar),
                       DeviceUsage(thisMonth: TrafficTotals(bytesUp: 10, bytesDown: 100), lastConnected: now))
        // A new launch's server starts from zero again.
        relaunched.record(snapshot([ipad.address: used(1, 1)]), peers: [ipad], now: now, calendar: calendar)
        XCTAssertEqual(relaunched.usage(of: ipad.id, now: now, calendar: calendar).thisMonth, TrafficTotals(bytesUp: 11, bytesDown: 101))
    }

    func testTheSavedDataSaysItsVersion() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: UsageLedger().saved()) as? [String: Any])
        XCTAssertEqual(json["v"] as? Int, 1)
    }

    func testAnotherVersionOrGarbageIsAnError() {
        XCTAssertThrowsError(try UsageLedger(saved: Data(#"{"v":2,"devices":{}}"#.utf8))) { error in
            XCTAssertEqual("\(error)", "version 2, this app reads 1")
        }
        XCTAssertThrowsError(try UsageLedger(saved: Data("not json".utf8)))
    }

    func testTotalsAddUp() {
        XCTAssertEqual(TrafficTotals(bytesUp: 420, bytesDown: 2700).total, 3120)
        XCTAssertEqual(TrafficTotals(bytesUp: .max, bytesDown: 1).total, .max, "a huge count doesn't trap")
    }
}
