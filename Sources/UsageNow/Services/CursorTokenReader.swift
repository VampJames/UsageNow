import Foundation

protocol CursorTokenReading: Sendable {
    func readAccessToken() throws -> String
}

struct CursorTokenReader: CursorTokenReading {
    private let databasePath: String
    private let sqlitePath: String

    init(
        databasePath: String? = nil,
        sqlitePath: String = "/usr/bin/sqlite3"
    ) {
        if let databasePath {
            self.databasePath = databasePath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.databasePath =
                "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        }
        self.sqlitePath = sqlitePath
    }

    func readAccessToken() throws -> String {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw CursorTokenError.notLoggedIn
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = [
            "-readonly",
            databasePath,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CursorTokenError.notLoggedIn
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            throw CursorTokenError.notLoggedIn
        }

        var raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.hasSuffix("\n") {
            raw = String(raw.dropLast())
        }
        guard !raw.isEmpty else {
            throw CursorTokenError.notLoggedIn
        }

        if let decoded = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) {
            return decoded
        }
        return raw
    }
}

enum CursorTokenError: Error, Equatable {
    case notLoggedIn
}
