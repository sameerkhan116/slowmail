import Foundation

/// Demo data. Dates are expressed relative to a fixed reference instant so the
/// whole app can be driven, tested, and screenshotted without waiting for days
/// to pass.
public struct Fixtures: Sendable {
    public let correspondents: [Correspondent]
    public let letters: [Letter]

    public init(correspondents: [Correspondent], letters: [Letter]) {
        self.correspondents = correspondents
        self.letters = letters
    }

    /// The instant every demo screen is rendered at: a Thursday afternoon,
    /// after the carrier has been but before the day's collection.
    public static let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 20
        components.hour = 15
        components.minute = 40
        components.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 1_787_000_000)
    }()

    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: components) ?? referenceDate
    }

    public static let demo = Fixtures(
        correspondents: [
            .init(id: "c-amara", name: "Amara Okafor", cityLabel: "Brooklyn, New York",
                  timeZoneIdentifier: "America/New_York", milesAway: 6, typicalTransitDays: 1),
            .init(id: "c-ben", name: "Ben Alvarez", cityLabel: "Austin, Texas",
                  timeZoneIdentifier: "America/Chicago", milesAway: 1_510, typicalTransitDays: 4),
            .init(id: "c-nour", name: "Nour Haddad", cityLabel: "London, England",
                  timeZoneIdentifier: "Europe/London", milesAway: 3_461, typicalTransitDays: 11),
            .init(id: "c-kenji", name: "Kenji Watanabe", cityLabel: "Kyoto, Japan",
                  timeZoneIdentifier: "Asia/Tokyo", milesAway: 6_750, typicalTransitDays: 14),
        ],
        letters: [
            // Arrived in today's post, unread. This is what the mailbox shows.
            .init(id: "l-001", correspondentID: "c-ben", isOutbound: false,
                  body: """
                  The garden finally gave up on the tomatoes, which I'm choosing to \
                  read as a lesson about ambition rather than about watering.

                  I've started walking to the post office instead of driving. It adds \
                  twenty minutes and I've decided those twenty minutes are the point.

                  Tell me about the move. All of it, not the summary.
                  """,
                  state: .delivered, writtenAt: at(14, 11), collectedAt: at(14, 17),
                  postmarkDate: at(14, 17), expectedDeliveryDate: at(20, 13),
                  deliveredAt: at(20, 13, 27)),

            .init(id: "l-002", correspondentID: "c-nour", isOutbound: false,
                  body: """
                  Three weeks of rain and then one afternoon so bright the whole street \
                  came outside to stand in it, blinking like we'd been let out of somewhere.

                  Your last letter took eleven days. I kept checking the mat like a dog.
                  """,
                  state: .delivered, writtenAt: at(6, 9), collectedAt: at(6, 17),
                  postmarkDate: at(6, 17), expectedDeliveryDate: at(20, 13),
                  deliveredAt: at(20, 13, 27)),

            // Read a few days ago; gives Correspondence something to show.
            .init(id: "l-003", correspondentID: "c-ben", isOutbound: false,
                  body: "Short one — the car died outside Waco and I have opinions about it now.",
                  state: .delivered, writtenAt: at(4, 10), collectedAt: at(4, 17),
                  postmarkDate: at(4, 17), expectedDeliveryDate: at(10, 12),
                  deliveredAt: at(10, 12, 14), readAt: at(10, 19)),

            .init(id: "l-004", correspondentID: "c-amara", isOutbound: false,
                  body: "Coffee Saturday? I'll write properly after, this is just the asking part.",
                  state: .delivered, writtenAt: at(17, 8), collectedAt: at(17, 17),
                  postmarkDate: at(17, 17), expectedDeliveryDate: at(18, 10),
                  deliveredAt: at(18, 10, 41), readAt: at(18, 20)),

            // Written today, not yet collected: still editable, still revocable.
            .init(id: "l-005", correspondentID: "c-ben", isOutbound: true,
                  body: """
                  The move happened in the least graceful way available. I'll spare you \
                  the inventory of what broke and tell you instead that the new kitchen \
                  gets light until about four.
                  """,
                  state: .awaitingCollection, writtenAt: at(20, 14, 5),
                  postmarkDate: at(20, 17), expectedDeliveryDate: at(25, 12)),

            // Collected days ago, still travelling. No longer revocable.
            .init(id: "l-006", correspondentID: "c-kenji", isOutbound: true,
                  body: "A long one about the river, which I will regret having sent at this length.",
                  state: .inTransit, writtenAt: at(12, 20), collectedAt: at(13, 17),
                  postmarkDate: at(13, 17), expectedDeliveryDate: at(27, 11)),

            .init(id: "l-007", correspondentID: "c-amara", isOutbound: true,
                  body: "Saturday works. I'll bring the book I keep failing to describe to you.",
                  state: .inTransit, writtenAt: at(19, 9), collectedAt: at(19, 17),
                  postmarkDate: at(19, 17), expectedDeliveryDate: at(21, 14)),
        ]
    )

    /// A day with nothing in it. The empty mailbox is a real state and it needs
    /// to feel intentional rather than broken.
    public static let quietDay = Fixtures(
        correspondents: demo.correspondents,
        letters: demo.letters.filter { $0.isOutbound }
    )
}
