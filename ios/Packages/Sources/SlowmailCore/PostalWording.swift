import Foundation

/// How the app talks about time.
///
/// The rule underneath all of this: never tell someone when a particular letter
/// will arrive. Mail arrives on a day, not at 14:32, and a countdown is the one
/// thing this app exists to remove.
///
/// The rule is about specific letters, not about clock times as such. Onboarding
/// says the carrier comes between nine and five, which is the mechanic itself and
/// is the same sentence for everyone; it tells you the app will not tell you more.
/// Collection is stated exactly, because five o'clock is a deadline the sender
/// can still act on rather than a prediction about someone else's mail.
public enum PostalWording {
    public static func postmark(_ date: Date, calendar: Calendar = .postal) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return "Postmarked \(formatter.string(from: date))"
    }

    /// Deliberately vague: a weekday and a date, never a time.
    /// Shown instead of an arrival date when the recipient has no address on
    /// file. It says why nothing can be quoted rather than leaving a blank.
    /// The one line that describes where a correspondent is and how long the
    /// post takes to reach them. It lives here, in one place, so that an
    /// unknown address cannot be rendered as a confident zero by one view and
    /// as a blank by another.
    public static func routing(miles: Int?, days: Int?) -> String {
        guard let miles, let days else { return unaddressed }
        return "\(distance(miles: miles)) · \(typicalTransit(days: days))"
    }

    public static let unaddressed = "No address on file — the post can't carry this yet"

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

    /// Stated to the minute because it is a deadline the sender can still act
    /// on, which is the one kind of precision this app owes anyone. Tense
    /// follows the clock: a letter still sitting in the postbox offers to be
    /// fetched back, so describing it as already collected contradicts itself.
    public static func collection(_ date: Date, asOf now: Date, calendar: Calendar = .postal)
        -> String
    {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE"
        let day = formatter.string(from: date)
        formatter.dateFormat = "h a"
        let time = formatter.string(from: date).lowercased()
        let when = "\(day) at \(time)"
        return now < date ? "Goes out \(when)" : "Collected \(when)"
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
    public static let nothingComingToday = "The post has been."
    /// Says the carrier is not expected, not that the day is closed. The round is
    /// an estimate the client and server can disagree about by up to an hour, so
    /// copy that forecloses the day can be contradicted a minute later by a
    /// letter appearing. See `MailStore.carrierExpected`.
    public static let emptyMailboxDetail = "The carrier isn't expected here again today."
    public static let postNotHereYet = "The post hasn't come yet."
    public static let emptyMailboxWaitingDetail = "The carrier is still out on today's round."
}
