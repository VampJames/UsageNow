import os

enum AppLog {
    private static let lifecycle = Logger(subsystem: "com.local.usagenow", category: "lifecycle")

    static func providerStarted(_ name: String) {
        lifecycle.info("Provider started: \(name, privacy: .public)")
    }

    static func providerStopped(_ name: String) {
        lifecycle.info("Provider stopped: \(name, privacy: .public)")
    }

    static func requestFailed(category: String) {
        lifecycle.error("Request failed: \(category, privacy: .public)")
    }

    static func codexAppServerRestarting() {
        lifecycle.info("Codex App Server restarting")
    }
}
