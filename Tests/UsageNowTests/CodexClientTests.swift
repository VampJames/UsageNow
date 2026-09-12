import XCTest
@testable import UsageNow

final class CodexClientTests: XCTestCase {
    func testRPCResultEnvelopeDecoding() throws {
        let json = """
        {
          "result": {
            "rateLimitsByLimitId": {
              "codex": {
                "primary": {"usedPercent": 5, "windowDurationMins": 300, "resetsAt": 100},
                "secondary": {"usedPercent": 6, "windowDurationMins": 10080, "resetsAt": 200}
              }
            }
          }
        }
        """
        let payload = try CodexRateLimitsParser.decodeRateLimits(from: Data(json.utf8))
        let snapshot = try CodexRateLimitsParser.snapshot(from: payload)
        XCTAssertEqual(snapshot.innerMetric.percentUsed, 5)
        XCTAssertEqual(snapshot.outerMetric.percentUsed, 6)
    }

    func testPendingRequestFailsWhenProcessExits() async {
        let failingClient = CodexAppServerClient(binaryLocator: TestFalseBinaryLocator())
        do {
            try await failingClient.startIfNeeded()
            XCTFail("expected failure")
        } catch let error as CodexAppServerError {
            XCTAssertTrue(error == .processExited || error == .processFailed || error == .timeout)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await failingClient.shutdown()
    }
}

private struct TestFalseBinaryLocator: CodexBinaryLocating {
    func locate() -> URL? { URL(fileURLWithPath: "/usr/bin/false") }
}
