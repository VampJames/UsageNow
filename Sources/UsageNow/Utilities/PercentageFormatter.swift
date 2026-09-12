import Foundation

enum PercentageFormatter {
    static func displayText(for percentUsed: Double) -> String {
        if percentUsed.isNaN { return "—" }
        return "\(Int(percentUsed.rounded()))%"
    }

    static func displayText(for percentUsed: Double?) -> String {
        guard let percentUsed else { return "—" }
        return displayText(for: percentUsed)
    }

    static func ringProgress(for percentUsed: Double) -> Double {
        if percentUsed.isNaN { return 0 }
        return min(max(percentUsed, 0), 100) / 100
    }
}
