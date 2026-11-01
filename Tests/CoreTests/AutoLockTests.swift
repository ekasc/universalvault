import XCTest
import Core

final class AutoLockTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_000_000)

    func testConfiguredMinutesAreClamped() {
        XCTAssertEqual(AutoLock.clampedMinutes(0), 1)
        XCTAssertEqual(AutoLock.clampedMinutes(-5), 1)
        XCTAssertEqual(AutoLock.clampedMinutes(10), 10)
        XCTAssertEqual(AutoLock.clampedMinutes(10_000), 1440)
    }

    func testLocksOnlyAfterTheConfiguredWindow() {
        let last = reference
        XCTAssertFalse(AutoLock.shouldLock(lastActivity: last, now: last.addingTimeInterval(299), configuredMinutes: 5))
        XCTAssertFalse(AutoLock.shouldLock(lastActivity: last, now: last.addingTimeInterval(300), configuredMinutes: 5))
        XCTAssertTrue(AutoLock.shouldLock(lastActivity: last, now: last.addingTimeInterval(301), configuredMinutes: 5))
    }

    func testOutOfRangeConfigurationBehavesAsClamped() {
        let last = reference
        // 0 minutes would otherwise lock instantly.
        XCTAssertFalse(AutoLock.shouldLock(lastActivity: last, now: last.addingTimeInterval(59), configuredMinutes: 0))
        XCTAssertTrue(AutoLock.shouldLock(lastActivity: last, now: last.addingTimeInterval(61), configuredMinutes: 0))
    }
}
