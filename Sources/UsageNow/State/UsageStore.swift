import Foundation
import Combine

protocol Clock: Sendable {
    func now() -> Date
    func sleep(nanoseconds: UInt64) async throws
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var codexState: ProviderState = .idle
    @Published private(set) var cursorState: ProviderState = .idle
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastRefreshCompletedAt: Date?

    private let codexProvider: UsageProvider
    private let cursorProvider: UsageProvider
    private let codexClient: CodexAppServerClient?
    private let clock: Clock

    private var scheduleTask: Task<Void, Never>?
    private var codexListenTask: Task<Void, Never>?
    private var codexInFlight = false
    private var cursorInFlight = false
    private var popoverOpen = false

    private let foregroundInterval: TimeInterval
    private let backgroundInterval: TimeInterval
    private let codexBackoffSeconds: [TimeInterval] = [5, 15, 30, 60, 120, 300]
    private var codexBackoffIndex = 0
    private var codexBackoffTask: Task<Void, Never>?
    private var lastCodexRateLimitsPayload: CodexRateLimitsPayload?

    init(
        codexProvider: UsageProvider = CodexUsageProvider(),
        cursorProvider: UsageProvider = CursorUsageProvider(),
        codexClient: CodexAppServerClient? = nil,
        clock: Clock = SystemClock(),
        foregroundInterval: TimeInterval = 60,
        backgroundInterval: TimeInterval = 300
    ) {
        self.foregroundInterval = foregroundInterval
        self.backgroundInterval = backgroundInterval
        self.codexProvider = codexProvider
        self.cursorProvider = cursorProvider
        if let codexClient {
            self.codexClient = codexClient
        } else if let provider = codexProvider as? CodexUsageProvider {
            self.codexClient = provider.clientForLifecycle()
        } else {
            self.codexClient = nil
        }
        self.clock = clock
    }

    func start() {
        AppLog.providerStarted("UsageNow")
        startCodexNotifications()
        reschedulePolling()
        Task { await refreshAll(manual: false) }
    }

    func shutdown() {
        AppLog.providerStopped("UsageNow")
        scheduleTask?.cancel()
        codexListenTask?.cancel()
        codexBackoffTask?.cancel()
        Task { await codexClient?.shutdown() }
    }

    func setPopoverOpen(_ open: Bool) {
        popoverOpen = open
        reschedulePolling()
        if open {
            Task { await refreshAll(manual: true) }
        }
    }

    func refresh() {
        Task { await refreshAll(manual: true) }
        resetCodexBackoffAndRetry()
    }

    private func resetCodexBackoffAndRetry() {
        codexBackoffIndex = 0
        codexBackoffTask?.cancel()
        codexBackoffTask = nil
    }

    private func startCodexNotifications() {
        guard let codexClient else { return }
        codexListenTask?.cancel()
        codexListenTask = Task { [weak self] in
            let stream = await codexClient.rateLimitUpdates()
            for await payload in stream {
                guard !Task.isCancelled else { break }
                await self?.handleCodexRateLimitUpdate(payload)
            }
        }
    }

    private func handleCodexRateLimitUpdate(_ payload: CodexRateLimitsPayload) async {
        let merged = CodexRateLimitsParser.merged(previous: lastCodexRateLimitsPayload, update: payload)
        if applyCodexPayload(merged) {
            return
        }
        guard let codexClient else { return }
        do {
            let full = try await codexClient.readRateLimits()
            lastCodexRateLimitsPayload = full
            applyCodexPayload(full)
        } catch {
            AppLog.requestFailed(category: "codex-push-fallback-read")
        }
    }

    @discardableResult
    private func applyCodexPayload(_ payload: CodexRateLimitsPayload) -> Bool {
        do {
            let snapshot = try CodexRateLimitsParser.snapshot(from: payload, fetchedAt: clock.now())
            lastCodexRateLimitsPayload = payload
            codexState = .available(snapshot)
            codexBackoffIndex = 0
            return true
        } catch {
            return false
        }
    }

    private func reschedulePolling() {
        scheduleTask?.cancel()
        let interval = popoverOpen ? foregroundInterval : backgroundInterval
        scheduleTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await clock.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await refreshAll(manual: false)
            }
        }
    }

    func refreshAll(manual: Bool) async {
        if isRefreshing && !manual { return }

        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshCompletedAt = clock.now()
        }
        await performRefresh()
    }

    private func performRefresh() async {
        async let codexResult: Void = refreshCodex()
        async let cursorResult: Void = refreshCursor()
        _ = await (codexResult, cursorResult)
    }

    private func refreshCodex() async {
        if codexInFlight { return }
        codexInFlight = true
        setLoadingIfNeeded(.codex)

        do {
            if let codexClient {
                let payload = try await codexClient.readRateLimits()
                lastCodexRateLimitsPayload = payload
                let snapshot = try CodexRateLimitsParser.snapshot(from: payload, fetchedAt: clock.now())
                codexState = .available(snapshot)
            } else {
                let snapshot = try await codexProvider.fetch()
                codexState = .available(snapshot)
            }
            codexBackoffIndex = 0
        } catch {
            AppLog.requestFailed(category: "codex")
            applyFailure(provider: .codex, error: error, message: CodexUserFacingError.message(for: error))
            scheduleCodexBackoff()
        }
        codexInFlight = false
    }

    private func refreshCursor() async {
        if cursorInFlight { return }
        cursorInFlight = true
        setLoadingIfNeeded(.cursor)

        do {
            let snapshot = try await cursorProvider.fetch()
            cursorState = .available(snapshot)
        } catch {
            AppLog.requestFailed(category: "cursor")
            let message = CursorUserFacingError.message(for: error)
            if CursorUserFacingError.isStalePreserving(error: error) {
                applyStale(provider: .cursor, message: message)
            } else {
                applyFailure(provider: .cursor, error: error, message: message)
            }
        }
        cursorInFlight = false
    }

    private func setLoadingIfNeeded(_ kind: UsageProviderKind) {
        switch kind {
        case .codex:
            if case .idle = codexState { codexState = .loading }
        case .cursor:
            if case .idle = cursorState { cursorState = .loading }
        }
    }

    private func applyFailure(provider: UsageProviderKind, error: Error, message: String) {
        switch provider {
        case .codex:
            if let snapshot = lastSnapshot(from: codexState) {
                codexState = .stale(snapshot: snapshot, message: message)
            } else {
                codexState = .unavailable(message: message)
            }
        case .cursor:
            if let snapshot = lastSnapshot(from: cursorState) {
                cursorState = .stale(snapshot: snapshot, message: message)
            } else {
                cursorState = .unavailable(message: message)
            }
        }
    }

    private func applyStale(provider: UsageProviderKind, message: String) {
        switch provider {
        case .codex:
            if let snapshot = lastSnapshot(from: codexState) {
                codexState = .stale(snapshot: snapshot, message: message)
            } else {
                codexState = .unavailable(message: message)
            }
        case .cursor:
            if let snapshot = lastSnapshot(from: cursorState) {
                cursorState = .stale(snapshot: snapshot, message: message)
            } else {
                cursorState = .unavailable(message: message)
            }
        }
    }

    private func lastSnapshot(from state: ProviderState) -> UsageSnapshot? {
        switch state {
        case .available(let s), .stale(let s, _):
            return s
        default:
            return nil
        }
    }

    private func scheduleCodexBackoff() {
        guard codexBackoffIndex < codexBackoffSeconds.count else { return }
        codexBackoffTask?.cancel()
        let delay = codexBackoffSeconds[codexBackoffIndex]
        codexBackoffIndex += 1
        codexBackoffTask = Task { [weak self] in
            try? await self?.clock.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            AppLog.codexAppServerRestarting()
            await self?.codexClient?.shutdown()
            await self?.refreshCodex()
        }
    }
}
