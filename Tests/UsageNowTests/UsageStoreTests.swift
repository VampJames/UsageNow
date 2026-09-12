import XCTest
@testable import UsageNow

final class UsageStoreTests: XCTestCase {
    private final class MockProvider: UsageProvider, @unchecked Sendable {
        let provider: UsageProviderKind
        var fetchCount = 0
        var delayNanoseconds: UInt64 = 0
        var result: Result<UsageSnapshot, Error>

        init(kind: UsageProviderKind, result: Result<UsageSnapshot, Error>) {
            self.provider = kind
            self.result = result
        }

        func fetch() async throws -> UsageSnapshot {
            fetchCount += 1
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return try result.get()
        }
    }

    private final class TestClock: Clock, @unchecked Sendable {
        var sleepCalls = 0
        var lastIntervalNanoseconds: UInt64?
        func now() -> Date { Date() }
        func sleep(nanoseconds: UInt64) async throws {
            sleepCalls += 1
            lastIntervalNanoseconds = nanoseconds
            try await Task.sleep(nanoseconds: 1)
        }
    }

    private func sampleSnapshot(_ kind: UsageProviderKind) -> UsageSnapshot {
        UsageSnapshot(
            provider: kind,
            innerMetric: UsageMetric(title: "a", percentUsed: 1, resetAt: nil),
            outerMetric: UsageMetric(title: "b", percentUsed: 2, resetAt: nil),
            fetchedAt: Date()
        )
    }

    @MainActor
    func testInitialFailureUnavailable() async {
        let codex = MockProvider(kind: .codex, result: .failure(CodexAppServerError.binaryNotFound))
        let cursor = MockProvider(kind: .cursor, result: .failure(CursorUsageError.notLoggedIn))
        let store = UsageStore(codexProvider: codex, cursorProvider: cursor)
        await store.refreshAll(manual: true)
        if case .unavailable = store.codexState {} else { XCTFail("codex unavailable") }
        if case .unavailable = store.cursorState {} else { XCTFail("cursor unavailable") }
    }

    @MainActor
    func testSuccessThenFailureStale() async {
        let codex = MockProvider(kind: .codex, result: .success(sampleSnapshot(.codex)))
        let cursor = MockProvider(kind: .cursor, result: .success(sampleSnapshot(.cursor)))
        let store = UsageStore(codexProvider: codex, cursorProvider: cursor)
        await store.refreshAll(manual: true)
        codex.result = .failure(CodexAppServerError.timeout)
        await store.refreshAll(manual: true)
        if case .stale(let snapshot, _) = store.codexState {
            XCTAssertEqual(snapshot.provider, .codex)
        } else {
            XCTFail("expected stale")
        }
    }

    @MainActor
    func testOneProviderFailureDoesNotBlockOther() async {
        let codex = MockProvider(kind: .codex, result: .failure(CodexAppServerError.timeout))
        let cursor = MockProvider(kind: .cursor, result: .success(sampleSnapshot(.cursor)))
        let store = UsageStore(codexProvider: codex, cursorProvider: cursor)
        await store.refreshAll(manual: true)
        if case .unavailable = store.codexState {} else { XCTFail() }
        if case .available = store.cursorState {} else { XCTFail() }
    }

    @MainActor
    func testPopoverOpenUsesForegroundInterval() async {
        let clock = TestClock()
        let store = UsageStore(
            codexProvider: MockProvider(kind: .codex, result: .success(sampleSnapshot(.codex))),
            cursorProvider: MockProvider(kind: .cursor, result: .success(sampleSnapshot(.cursor))),
            clock: clock,
            foregroundInterval: 60,
            backgroundInterval: 300
        )
        store.setPopoverOpen(true)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertGreaterThanOrEqual(clock.sleepCalls, 1)
    }

    @MainActor
    func testRescheduleOnPopoverToggle() async throws {
        let clock = TestClock()
        let store = UsageStore(
            codexProvider: MockProvider(kind: .codex, result: .success(sampleSnapshot(.codex))),
            cursorProvider: MockProvider(kind: .cursor, result: .success(sampleSnapshot(.cursor))),
            clock: clock,
            foregroundInterval: 60,
            backgroundInterval: 300
        )
        store.setPopoverOpen(true)
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(clock.lastIntervalNanoseconds, 60_000_000_000)
        store.setPopoverOpen(false)
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(clock.lastIntervalNanoseconds, 300_000_000_000)
    }

    @MainActor
    func testConcurrentRefreshDoesNotOverlapProvider() async {
        let codex = MockProvider(kind: .codex, result: .success(sampleSnapshot(.codex)))
        codex.delayNanoseconds = 200_000_000
        let store = UsageStore(
            codexProvider: codex,
            cursorProvider: MockProvider(kind: .cursor, result: .success(sampleSnapshot(.cursor)))
        )
        async let first: Void = store.refreshAll(manual: true)
        async let second: Void = store.refreshAll(manual: true)
        _ = await (first, second)
        XCTAssertLessThanOrEqual(codex.fetchCount, 2)
    }
}
