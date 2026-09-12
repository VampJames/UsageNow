import XCTest
@testable import UsageNow

final class CodexResponseTests: XCTestCase {
    private func officialCodexJSON(
        innerPercent: Double,
        innerResetsAt: Int,
        outerPercent: Double,
        outerResetsAt: Int,
        swapSlots: Bool = false,
        useTopLevelRateLimits: Bool = false
    ) -> String {
        let fiveHour = """
        {"usedPercent": \(innerPercent), "windowDurationMins": 300, "resetsAt": \(innerResetsAt)}
        """
        let weekly = """
        {"usedPercent": \(outerPercent), "windowDurationMins": 10080, "resetsAt": \(outerResetsAt)}
        """
        let primary = swapSlots ? weekly : fiveHour
        let secondary = swapSlots ? fiveHour : weekly
        let snapshot = """
        {
          "primary": \(primary),
          "secondary": \(secondary)
        }
        """
        if useTopLevelRateLimits {
            return """
            {
              "rateLimits": \(snapshot)
            }
            """
        }
        return """
        {
          "rateLimitsByLimitId": {
            "codex": \(snapshot)
          }
        }
        """
    }

    func testParseReadResponseOfficialStructure() throws {
        let json = officialCodexJSON(
            innerPercent: 42,
            innerResetsAt: 1_700_000_000,
            outerPercent: 67,
            outerResetsAt: 1_701_000_000
        )
        let payload = try CodexRateLimitsParser.decodeRateLimits(from: Data(json.utf8))
        let snapshot = try CodexRateLimitsParser.snapshot(from: payload)
        XCTAssertEqual(snapshot.innerMetric.percentUsed, 42)
        XCTAssertEqual(snapshot.outerMetric.percentUsed, 67)
        XCTAssertEqual(snapshot.innerMetric.title, "5 小时")
    }

    func testPrimarySecondarySlotSwapStillMapsByWindowDuration() throws {
        let json = officialCodexJSON(
            innerPercent: 42,
            innerResetsAt: 2,
            outerPercent: 67,
            outerResetsAt: 1,
            swapSlots: true
        )
        let payload = try CodexRateLimitsParser.decodeRateLimits(from: Data(json.utf8))
        let snapshot = try CodexRateLimitsParser.snapshot(from: payload)
        XCTAssertEqual(snapshot.innerMetric.percentUsed, 42)
        XCTAssertEqual(snapshot.outerMetric.percentUsed, 67)
    }

    func testParseUpdatedNotificationOfficialStructure() throws {
        let json = """
        {
          "params": {
            "rateLimitsByLimitId": {
              "codex": {
                "primary": {"usedPercent": 20, "windowDurationMins": 300, "resetsAt": 2},
                "secondary": {"usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1}
              }
            }
          }
        }
        """
        let payload = try CodexRateLimitsParser.decodeRateLimits(from: Data(json.utf8))
        let snapshot = try CodexRateLimitsParser.snapshot(from: payload)
        XCTAssertEqual(snapshot.innerMetric.percentUsed, 20)
        XCTAssertEqual(snapshot.outerMetric.percentUsed, 10)
    }

    func testPrefersRateLimitsByLimitIdOverTopLevelRateLimits() throws {
        let json = """
        {
          "rateLimits": {
            "primary": {"usedPercent": 1, "windowDurationMins": 300, "resetsAt": 1}
          },
          "rateLimitsByLimitId": {
            "codex": {
              "primary": {"usedPercent": 55, "windowDurationMins": 300, "resetsAt": 2},
              "secondary": {"usedPercent": 77, "windowDurationMins": 10080, "resetsAt": 3}
            }
          }
        }
        """
        let payload = try CodexRateLimitsParser.decodeRateLimits(from: Data(json.utf8))
        let snapshot = try CodexRateLimitsParser.snapshot(from: payload)
        XCTAssertEqual(snapshot.innerMetric.percentUsed, 55)
        XCTAssertEqual(snapshot.outerMetric.percentUsed, 77)
    }

    func testTopLevelRateLimitsFallback() throws {
        let json = officialCodexJSON(
            innerPercent: 12,
            innerResetsAt: 1,
            outerPercent: 34,
            outerResetsAt: 2,
            useTopLevelRateLimits: true
        )
        let payload = try CodexRateLimitsParser.decodeRateLimits(from: Data(json.utf8))
        let snapshot = try CodexRateLimitsParser.snapshot(from: payload)
        XCTAssertEqual(snapshot.innerMetric.percentUsed, 12)
        XCTAssertEqual(snapshot.outerMetric.percentUsed, 34)
    }

    func testMissingFiveHourWindowDoesNotUseWeeklyForInner() throws {
        let json = """
        {
          "rateLimitsByLimitId": {
            "codex": {
              "secondary": {"usedPercent": 67, "windowDurationMins": 10080, "resetsAt": 1701000000}
            }
          }
        }
        """
        let payload = try CodexRateLimitsParser.decodeRateLimits(from: Data(json.utf8))
        let snapshot = try CodexRateLimitsParser.snapshot(from: payload)
        XCTAssertTrue(snapshot.innerMetric.percentUsed.isNaN)
        XCTAssertEqual(snapshot.outerMetric.percentUsed, 67)
    }

    func testSparseNotificationMergePreservesOtherRing() throws {
        let fullJSON = officialCodexJSON(
            innerPercent: 40,
            innerResetsAt: 10,
            outerPercent: 67,
            outerResetsAt: 20
        )
        let full = try CodexRateLimitsParser.decodeRateLimits(from: Data(fullJSON.utf8))

        let sparseJSON = """
        {
          "params": {
            "rateLimits": {
              "primary": {
                "usedPercent": 50,
                "windowDurationMins": 300,
                "resetsAt": 11
              }
            }
          }
        }
        """
        let sparse = try CodexRateLimitsParser.decodeRateLimits(from: Data(sparseJSON.utf8))
        let merged = CodexRateLimitsParser.merged(previous: full, update: sparse)
        let snapshot = try CodexRateLimitsParser.snapshot(from: merged)

        XCTAssertEqual(snapshot.innerMetric.percentUsed, 50)
        XCTAssertEqual(snapshot.outerMetric.percentUsed, 67)
    }

    func testResetsAtUnixSeconds() throws {
        let json = officialCodexJSON(
            innerPercent: 1,
            innerResetsAt: 1_700_000_000,
            outerPercent: 2,
            outerResetsAt: 3
        )
        let payload = try CodexRateLimitsParser.decodeRateLimits(from: Data(json.utf8))
        let (fiveHour, _) = CodexRateLimitsParser.windows(in: payload)
        let date = fiveHour?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_700_000_000))
    }
}
