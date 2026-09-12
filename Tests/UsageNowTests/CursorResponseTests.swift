import XCTest
@testable import UsageNow

final class CursorResponseTests: XCTestCase {
    private struct MockTransport: HTTPTransport {
        let statusCode: Int
        let body: Data

        func data(for request: HTTPRequest) async throws -> HTTPResponse {
            HTTPResponse(statusCode: statusCode, body: body)
        }
    }

    private struct MockTokenReader: CursorTokenReading {
        func readAccessToken() throws -> String { "fixture-token-not-real" }
    }

    func testMapsApiToInnerAndAutoToOuter() async throws {
        let body = """
        {"planUsage":{"apiPercentUsed":21,"autoPercentUsed":8}}
        """
        let provider = CursorUsageProvider(
            tokenReader: MockTokenReader(),
            transport: MockTransport(statusCode: 200, body: Data(body.utf8))
        )
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.innerMetric.title, "Other Models")
        XCTAssertEqual(snapshot.innerMetric.percentUsed, 21)
        XCTAssertEqual(snapshot.outerMetric.title, "Cursor Models")
        XCTAssertEqual(snapshot.outerMetric.percentUsed, 8)
    }

    func testPercentEdgeCases() async throws {
        for (api, auto) in [(0.0, 100.0), (112.5, 50.0)] {
            let body = """
            {"planUsage":{"apiPercentUsed":\(api),"autoPercentUsed":\(auto)}}
            """
            let provider = CursorUsageProvider(
                tokenReader: MockTokenReader(),
                transport: MockTransport(statusCode: 200, body: Data(body.utf8))
            )
            let snapshot = try await provider.fetch()
            XCTAssertEqual(snapshot.innerMetric.percentUsed, api)
            XCTAssertEqual(snapshot.outerMetric.percentUsed, auto)
        }
    }

    func testMissingPlanUsage() async {
        let provider = CursorUsageProvider(
            tokenReader: MockTokenReader(),
            transport: MockTransport(statusCode: 200, body: Data("{}".utf8))
        )
        do {
            _ = try await provider.fetch()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? CursorUsageError, .schemaChanged)
        }
    }

    func testHTTPStatusMapping() async {
        let cases: [(Int, CursorUsageError)] = [
            (401, .unauthorized),
            (403, .unauthorized),
            (404, .notFound),
            (429, .tooManyRequests),
            (500, .serverError),
        ]
        for (code, expected) in cases {
            let provider = CursorUsageProvider(
                tokenReader: MockTokenReader(),
                transport: MockTransport(statusCode: code, body: Data("{}".utf8))
            )
            do {
                _ = try await provider.fetch()
                XCTFail("expected error for \(code)")
            } catch {
                XCTAssertEqual(error as? CursorUsageError, expected)
            }
        }
    }

    func testTokenReaderJSONEncodedString() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDB) }

        let dbPath = tempDB.appendingPathComponent("state.vscdb").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, "CREATE TABLE ItemTable (key TEXT, value TEXT);"]
        try process.run()
        process.waitUntilExit()

        let encoded = "\"json-token-value\""
        let insert = Process()
        insert.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        insert.arguments = [
            dbPath,
            "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', '\(encoded)');",
        ]
        try insert.run()
        insert.waitUntilExit()

        let reader = CursorTokenReader(databasePath: dbPath)
        XCTAssertEqual(try reader.readAccessToken(), "json-token-value")
    }

    func testTokenReaderPlainString() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDB) }

        let dbPath = tempDB.appendingPathComponent("state.vscdb").path
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        create.arguments = [dbPath, "CREATE TABLE ItemTable (key TEXT, value TEXT);"]
        try create.run()
        create.waitUntilExit()

        let insert = Process()
        insert.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        insert.arguments = [
            dbPath,
            "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', 'plain-token');",
        ]
        try insert.run()
        insert.waitUntilExit()

        let reader = CursorTokenReader(databasePath: dbPath)
        XCTAssertEqual(try reader.readAccessToken(), "plain-token")
    }
}
