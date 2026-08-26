import Foundation

enum ParserHelpers {

    private nonisolated(unsafe) static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO8601(_ string: String) -> Date? {
        iso8601WithFractional.date(from: string) ?? iso8601Plain.date(from: string)
    }

    static func matchesFilter(_ date: Date, filter: DateComponents, calendar: Calendar) -> Bool {
        if let year = filter.year, calendar.component(.year, from: date) != year { return false }
        if let month = filter.month, calendar.component(.month, from: date) != month { return false }
        if let day = filter.day, calendar.component(.day, from: date) != day { return false }
        return true
    }
    static func matchesInterval(_ date: Date?, interval: DateInterval?) -> Bool {
        guard let interval else { return true } 
        guard let date else { return false }   
        return interval.contains(date)
    }
}
