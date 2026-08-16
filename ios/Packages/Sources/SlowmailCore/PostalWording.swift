import Foundation

/// How the app talks about time.
///
/// The rule underneath all of this: never state a delivery time more precisely
/// than the post can honour. Mail arrives on a day, not at 14:32, and saying
/// otherwise turns anticipation into a countdown.
public enum PostalWording {
    public static func postmark(_ date: Date, calendar: Calendar = .postal) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return "Postmarked \(formatter.string(from: date))"
    }

    /// Deliberately vague: a weekday and a date, never a time.
    public static func expectedArrival(_ date: Date, calendar: Calendar = .postal) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM"
        return "Should arrive around \(formatter.string(from: date))"
    }

    public static func arrivedOn(_ date: Date, now: Date, calendar: Calendar = .postal) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Arrived today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Arrived yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM"
        return "Arrived \(formatter.string(from: date))"
    }

    /// The collection deadline, which is the only precise time the app ever shows —
    /// because it is a deadline the user can act on, not a prediction.
    public static func collectionDeadline(_ date: Date, calendar: Calendar = .postal) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h a"
        return "Collected at \(formatter.string(from: date).lowercased())"
    }

    public static func distance(miles: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let value = formatter.string(from: NSNumber(value: miles)) ?? "\(miles)"
        return miles == 1 ? "1 mile away" : "\(value) miles away"
    }

    public static func typicalTransit(days: Int) -> String {
        switch days {
        case ..<2: return "about a day each way"
        case 2...6: return "about \(days) days each way"
        case 7...10: return "about a week and a half each way"
        default: return "about \(days) days each way"
        }
    }

    /// Shown when today's post has not been yet. Never a countdown.
    public static let carrierNotYetBeen = "The carrier hasn't been yet today."
    public static let nothingComingToday = "No mail today."
    public static let emptyMailboxDetail = "Nothing was posted to you in time for today's round."
    public static let postNotHereYet = "The post hasn't come yet."
    public static let emptyMailboxWaitingDetail = "The carrier is still out. Whatever is coming will be here by five."
}
