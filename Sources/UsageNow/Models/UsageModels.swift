import Foundation

enum UsageProviderKind: String, Sendable {
    case codex
    case cursor
}

struct UsageMetric: Sendable, Equatable {
    let title: String
    let percentUsed: Double
    let resetAt: Date?
}

struct UsageSnapshot: Sendable, Equatable {
    let provider: UsageProviderKind
    let innerMetric: UsageMetric
    let outerMetric: UsageMetric
    let fetchedAt: Date
}

enum ProviderState: Equatable {
    case idle
    case loading
    case available(UsageSnapshot)
    case stale(snapshot: UsageSnapshot, message: String)
    case unavailable(message: String)
}
