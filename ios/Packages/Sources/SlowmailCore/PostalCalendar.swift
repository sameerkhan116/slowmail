import Foundation

public extension Calendar {
    /// One calendar for every date decision, so nothing depends on the device
    /// locale. Computed rather than cached because the time zone can change
    /// under a running app, and a stale zone silently shifts every "today".
    static var postal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        return calendar
    }
}

/// Client-side estimation of when mail moves.
///
/// This produces the dates shown before a letter is posted — "should arrive
/// around Thursday". The server decides the real schedule and its answer wins;
/// the app never treats these as facts. Holidays are deliberately not modelled
/// here, because an estimate that is a day out is fine and a second copy of the
/// holiday rules that can drift from the server's is not.
public enum PostalCalendar {
    public static let collectionHour = 17

    public static func isPostalDay(_ date: Date, calendar: Calendar = .postal) -> Bool {
        calendar.component(.weekday, from: date) != 1
    }

    /// The next time the box is emptied at or after `date`.
    public static func nextCollection(after date: Date, calendar: Calendar = .postal) -> Date {
        var candidate = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        let missedTodaysPickup = hour >= collectionHour || !isPostalDay(date, calendar: calendar)
        if missedTodaysPickup { candidate = nextPostalDay(after: candidate, calendar: calendar) }
        return calendar.date(bySettingHour: collectionHour, minute: 0, second: 0, of: candidate) ?? candidate
    }

    public static func nextPostalDay(after date: Date, calendar: Calendar = .postal) -> Date {
        var cursor = date
        repeat {
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        } while !isPostalDay(cursor, calendar: calendar)
        return cursor
    }

    public static func addingPostalDays(_ count: Int, to date: Date, calendar: Calendar = .postal) -> Date {
        var cursor = date
        for _ in 0..<max(0, count) { cursor = nextPostalDay(after: cursor, calendar: calendar) }
        return cursor
    }
}
