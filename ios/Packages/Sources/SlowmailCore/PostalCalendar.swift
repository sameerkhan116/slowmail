import Foundation
import MailClockKit

public extension Calendar {
    /// One calendar for every date decision, so nothing depends on the device
    /// locale. Computed rather than cached because the time zone can change
    /// under a running app, and a stale zone silently shifts every "today".
    /// Fixed at UTC, for reading the parts out of a value that already is UTC.
    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static var postal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        return calendar
    }
}

/// Date-based adapter from the app's API to the shared postal scheduling rules.
public enum PostalCalendar {
    public static let collectionHour = MailClockKit.collectionHour
    public static let earliestDeliveryHour = MailClockKit.arrivalWindowStartHour
    public static let latestDeliveryHour = MailClockKit.arrivalWindowEndHour

    /// How far a client's idea of the round may run ahead of the server's.
    ///
    /// Both draw the same wall-clock time from the same seed, but resolve it
    /// against their own timezone database. Where those disagree about a zone's
    /// rules the same local time is a different instant, and the largest such
    /// disagreement in practice is a one-hour offset change. A client that
    /// stops watching at its own round would otherwise miss mail the server is
    /// still holding.
    public static let maximumRoundSkew: TimeInterval = 60 * 60

    public static func isPostalDay(_ date: Date, calendar: Calendar = .postal) -> Bool {
        engineResult {
            try MailClockKit.isPostalDay(isoDate(for: date, calendar: calendar))
        }
    }

    /// The next time the box is emptied at or after `date`.
    public static func nextCollection(after date: Date, calendar: Calendar = .postal) -> Date {
        let collection = engineResult {
            try MailClockKit.nextCollection(
                writtenAt: instantString(for: date),
                senderTimeZone: calendar.timeZone.identifier
            )
        }
        return instantDate(from: collection.at)
    }

    public static func nextPostalDay(after date: Date, calendar: Calendar = .postal) -> Date {
        let next = engineResult {
            try MailClockKit.nextPostalDay(isoDate(for: date, calendar: calendar))
        }
        return localDate(next, preservingTimeFrom: date, calendar: calendar)
    }

    public static func addingPostalDays(
        _ count: Int,
        to date: Date,
        calendar: Calendar = .postal
    ) -> Date {
        let result = engineResult {
            try MailClockKit.addPostalDays(
                isoDate(for: date, calendar: calendar),
                count: max(0, count)
            )
        }
        return localDate(result, preservingTimeFrom: date, calendar: calendar)
    }

    /// When mail collected at `collection` should land.
    public static func arrival(
        after collection: Date,
        transit: Transit,
        calendar: Calendar = .postal
    ) -> Date {
        switch transit.unit {
        case .postalDays:
            return addingPostalDays(transit.days, to: collection, calendar: calendar)
        case .calendarDays:
            let raw = calendar.date(
                byAdding: .day,
                value: max(0, transit.days),
                to: collection
            ) ?? collection
            // The app has no destination holiday calendar here. A non-US code
            // selects MailClockKit's international rule: skip Sunday only.
            let deliveryDate = engineResult {
                try MailClockKit.rollToDeliveryDay(
                    isoDate(for: raw, calendar: calendar),
                    countryCode: "ZZ"
                )
            }
            return localDate(deliveryDate, preservingTimeFrom: raw, calendar: calendar)
        }
    }

    /// When the carrier reaches an address on a given day, or nil if they don't.
    ///
    /// Seeded on the address and the date and nothing else — deliberately not on
    /// what is in the bag. If this were derived from pending mail, the app could
    /// only say "the carrier hasn't been yet" when something was actually coming,
    /// and that difference would tell a recipient a letter exists before it has
    /// been delivered. The whole privacy guarantee leaks through an empty state.
    public static func carrierArrival(
        forRecipient recipientID: String,
        on day: Date,
        calendar: Calendar = .postal
    ) -> Date? {
        guard isPostalDay(day, calendar: calendar) else { return nil }
        let arrival = engineResult {
            try MailClockKit.carrierArrival(
                userId: recipientID,
                localDate: isoDate(for: day, calendar: calendar),
                timeZone: calendar.timeZone.identifier
            )
        }
        return instantDate(from: arrival)
    }

    private static func isoDate(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    private static func instantString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func instantDate(from instant: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: instant) else {
            preconditionFailure("MailClockKit returned an invalid instant: \(instant)")
        }
        return date
    }

    private static func localDate(
        _ isoDate: String,
        preservingTimeFrom source: Date,
        calendar: Calendar
    ) -> Date {
        let dateParts = isoDate.split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else {
            preconditionFailure("MailClockKit returned an invalid date: \(isoDate)")
        }
        var parts = calendar.dateComponents(
            [.hour, .minute, .second, .nanosecond],
            from: source
        )
        parts.timeZone = calendar.timeZone
        parts.year = dateParts[0]
        parts.month = dateParts[1]
        parts.day = dateParts[2]
        guard let date = calendar.date(from: parts) else {
            preconditionFailure(
                "MailClockKit date \(isoDate) is invalid in \(calendar.timeZone.identifier)"
            )
        }
        return date
    }

    private static func engineResult<Value>(
        _ operation: () throws -> Value
    ) -> Value {
        do {
            return try operation()
        } catch {
            preconditionFailure("MailClockKit adapter failed: \(error)")
        }
    }
}
