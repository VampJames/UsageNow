import Foundation

enum ResetTimeFormatter {
    static func format(resetAt: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let resetAt else { return "重置时间不可用" }
        if resetAt <= now {
            return "正在重置"
        }
        let interval = resetAt.timeIntervalSince(now)
        let oneDay: TimeInterval = 24 * 3600
        let sevenDays: TimeInterval = 7 * oneDay

        let timeString = timeFormatter.string(from: resetAt)

        if interval < oneDay {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            return "\(hours) 小时 \(minutes) 分后（\(timeString)）"
        }
        if interval <= sevenDays {
            let days = Int(interval / oneDay)
            let weekday = weekdayFormatter.string(from: resetAt)
            return "\(days) 天后（\(weekday) \(timeString)）"
        }
        let weekday = weekdayFormatter.string(from: resetAt)
        return "\(weekday) \(timeString)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = .current
        return f
    }()
}
