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
    /// The carrier's round. Officially 08:00-20:00; in practice this.
    public static let earliestDeliveryHour = 9
    public static let latestDeliveryHour = 17

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

public extension PostalCalendar {
    /// When mail collected at `collection` should land.
    static func arrival(after collection: Date, transit: Transit, calendar: Calendar = .postal) -> Date {
        switch transit.unit {
        case .postalDays:
            return addingPostalDays(transit.days, to: collection, calendar: calendar)
        case .calendarDays:
            let raw = calendar.date(byAdding: .day, value: max(0, transit.days), to: collection) ?? collection
            // However far it has come, it still cannot be delivered on a Sunday.
            return isPostalDay(raw, calendar: calendar) ? raw : nextPostalDay(after: raw, calendar: calendar)
        }
    }

    /// When the carrier reaches an address on a given day, or nil if they don't.
    ///
    /// Seeded on the address and the date and nothing else — deliberately not on
    /// what is in the bag. If this were derived from pending mail, the app could
    /// only say "the carrier hasn't been yet" when something was actually coming,
    /// and that difference would tell a recipient a letter exists before it has
    /// been delivered. The whole privacy guarantee leaks through an empty state.
    static func carrierArrival(
        forRecipient recipientID: String,
        on day: Date,
        calendar: Calendar = .postal
    ) -> Date? {
        guard isPostalDay(day, calendar: calendar) else { return nil }
        let start = calendar.startOfDay(for: day)
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        let key = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        // Namespace, quantisation and range all have to match the scheduling
        // engine exactly, or the app and the server disagree about when the
        // carrier came. Minutes, not seconds, over an inclusive 480-wide range.
        let windowMinutes = (latestDeliveryHour - earliestDeliveryHour) * 60
        let offset = Hashing.intInRange(0, windowMinutes - 1, "carrier-arrival", recipientID, key)
        // Adding seconds to midnight is not a local time: on a day that starts
        // at 01:00 because the clocks moved, it lands outside nine-to-five.
        var wall = calendar.dateComponents([.year, .month, .day], from: start)
        wall.hour = earliestDeliveryHour + offset / 60
        wall.minute = offset % 60
        return calendar.date(from: wall)
    }
}
