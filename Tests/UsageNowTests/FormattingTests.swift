import XCTest
@testable import UsageNow

final class FormattingTests: XCTestCase {
    func testResetWithin24Hours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(2 * 3600 + 13 * 60)
        let text = ResetTimeFormatter.format(resetAt: reset, now: now)
        XCTAssertTrue(text.contains("2 小时 13 分后"))
    }

    func testExpiredReset() {
        let now = Date()
        let text = ResetTimeFormatter.format(resetAt: now.addingTimeInterval(-10), now: now)
        XCTAssertEqual(text, "正在重置")
    }

    func testMissingReset() {
        XCTAssertEqual(ResetTimeFormatter.format(resetAt: nil), "重置时间不可用")
    }

    func testNegativeRingClampedTextPreserved() {
        XCTAssertEqual(PercentageFormatter.ringProgress(for: -5), 0)
        XCTAssertEqual(PercentageFormatter.displayText(for: -5), "-5%")
    }

    func testOver100RingSaturated() {
        XCTAssertEqual(PercentageFormatter.ringProgress(for: 112), 1)
        XCTAssertEqual(PercentageFormatter.displayText(for: 112), "112%")
    }

    func testNaNDisplayDash() {
        XCTAssertEqual(PercentageFormatter.displayText(for: Double.nan), "—")
    }

    func testRemainingPercentage() {
        XCTAssertEqual(PercentageFormatter.remainingDisplayText(for: 42), "58%")
        XCTAssertEqual(PercentageFormatter.remainingRingProgress(for: 42), 0.58, accuracy: 0.0001)
    }

    func testRemainingPercentageClampsRingOnly() {
        XCTAssertEqual(PercentageFormatter.remainingDisplayText(for: -5), "105%")
        XCTAssertEqual(PercentageFormatter.remainingRingProgress(for: -5), 1)
        XCTAssertEqual(PercentageFormatter.remainingDisplayText(for: 112), "-12%")
        XCTAssertEqual(PercentageFormatter.remainingRingProgress(for: 112), 0)
    }

    func testRemainingNaNDisplayDash() {
        XCTAssertEqual(PercentageFormatter.remainingDisplayText(for: Double.nan), "—")
        XCTAssertEqual(PercentageFormatter.remainingRingProgress(for: Double.nan), 0)
    }
}
