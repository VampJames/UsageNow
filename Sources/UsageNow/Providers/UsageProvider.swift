import Foundation

protocol UsageProvider: Sendable {
    var provider: UsageProviderKind { get }
    func fetch() async throws -> UsageSnapshot
}
