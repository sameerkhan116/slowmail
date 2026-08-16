import Foundation

public struct PostalDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else {
            throw MailClockError.invalidDate(
                String(format: "%04d-%02d-%02d", year, month, day)
            )
        }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            throw MailClockError.invalidDate(
                String(format: "%04d-%02d-%02d", year, month, day)
            )
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ isoDate: String) throws {
        let parts = isoDate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            throw MailClockError.invalidDate(isoDate)
        }
        try self.init(year: year, month: month, day: day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: PostalDate, rhs: PostalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    func adding(days: Int) throws -> PostalDate {
        let calendar = Self.utcCalendar
        guard let next = calendar.date(byAdding: .day, value: days, to: utcDate) else {
            throw MailClockError.invalidDate(description)
        }
        let components = calendar.dateComponents([.year, .month, .day], from: next)
        return try PostalDate(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    var weekday: Int {
        Self.utcCalendar.component(.weekday, from: utcDate)
    }

    var utcDate: Date {
        Self.utcCalendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

func parseInstant(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        throw MailClockError.invalidInstant(value)
    }
    return date
}

func formatInstant(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [
        .withInternetDateTime,
        .withFractionalSeconds,
        .withDashSeparatorInDate,
        .withColonSeparatorInTime,
    ]
    return formatter.string(from: date)
}

public func wallClock(
    _ isoDate: String,
    hour: Int,
    minute: Int,
    timeZone: String
) throws -> Date {
    try wallClock(
        PostalDate(isoDate),
        hour: hour,
        minute: minute,
        timeZone: timeZone
    )
}

func wallClock(_ date: PostalDate, hour: Int, minute: Int, timeZone: String) throws -> Date {
    guard let zone = TimeZone(identifier: timeZone) else {
        throw MailClockError.invalidTimeZone(timeZone)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let components = DateComponents(
        timeZone: zone,
        year: date.year,
        month: date.month,
        day: date.day,
        hour: hour,
        minute: minute,
        second: 0
    )
    guard let instant = calendar.date(from: components) else {
        throw MailClockError.invalidDate("\(date) \(hour):\(minute) \(timeZone)")
    }
    return instant
}
