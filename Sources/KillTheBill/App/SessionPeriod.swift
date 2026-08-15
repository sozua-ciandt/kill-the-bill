import Foundation

enum SessionPeriodPreset: String, CaseIterable, Identifiable, Sendable {
    case day
    case month
    case year
    case all
    case custom

    var id: String { rawValue }

    func interval(
        now: Date = Date(),
        customStart: Date,
        customEnd: Date,
        calendar: Calendar = .current
    ) -> DateInterval? {
        switch self {
        case .day:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return DateInterval(start: start, end: end)

        case .month:
            guard let start = calendar.date(
                from: calendar.dateComponents([.year, .month], from: now)
            ), let end = calendar.date(byAdding: .month, value: 1, to: start) else {
                return nil
            }
            return DateInterval(start: start, end: end)

        case .year:
            guard let start = calendar.date(
                from: calendar.dateComponents([.year], from: now)
            ), let end = calendar.date(byAdding: .year, value: 1, to: start) else {
                return nil
            }
            return DateInterval(start: start, end: end)

        case .all:
            return nil

        case .custom:
            let firstDay = calendar.startOfDay(for: min(customStart, customEnd))
            let lastDay = calendar.startOfDay(for: max(customStart, customEnd))
            let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            return DateInterval(start: firstDay, end: exclusiveEnd)
        }
    }
}
