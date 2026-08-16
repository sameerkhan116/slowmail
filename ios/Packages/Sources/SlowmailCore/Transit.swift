import Foundation

/// How long mail takes, and in which kind of day.
///
/// The distinction matters: domestic mail moves on postal days and sits still
/// on a Sunday, while international mail is in the air and in foreign systems
/// that do not share the US calendar, so it is quoted in calendar days. Folding
/// both into a plain day count silently adds a Sunday to every international
/// letter for each week it travels.
public struct Transit: Sendable, Hashable, Codable {
    public enum Unit: String, Sendable, Codable {
        case postalDays
        case calendarDays
    }

    public let days: Int
    public let unit: Unit

    public init(days: Int, unit: Unit) {
        self.days = days
        self.unit = unit
    }

    public static func domestic(_ days: Int) -> Transit { Transit(days: days, unit: .postalDays) }
    public static func international(_ days: Int) -> Transit { Transit(days: days, unit: .calendarDays) }
}
