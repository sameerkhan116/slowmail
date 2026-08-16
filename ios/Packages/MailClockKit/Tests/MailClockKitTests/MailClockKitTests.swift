import Foundation
import Testing

@testable import MailClockKit

private struct Fixtures: Decodable, Sendable {
    let parties: [String: FixtureParty]
    let hashVectors: [HashVector]
    let observedHolidays2026: [String]
    let postalDays: [PostalDayCase]
    let transitBands: [TransitBandCase]
    let internationalBands: [InternationalBandCase]
    let jitterBranches: [JitterCase]
    let collection: [CollectionCase]
    let schedule: [ScheduleCase]
}

private struct FixtureParty: Decodable, Sendable {
    let tz: String
    let lat: Double
    let lng: Double
    let countryCode: String
    let region: String?
    let isTerritory: Bool?
    let userId: String?

    var party: Party {
        Party(
            timeZone: tz,
            latitude: lat,
            longitude: lng,
            countryCode: countryCode,
            region: region,
            isTerritory: isTerritory ?? false
        )
    }

    var recipient: Recipient {
        get throws {
            guard let userId else {
                throw FixtureError.missingUserId
            }
            return Recipient(
                timeZone: tz,
                latitude: lat,
                longitude: lng,
                countryCode: countryCode,
                region: region,
                isTerritory: isTerritory ?? false,
                userId: userId
            )
        }
    }
}

private struct HashVector: Decodable, Sendable {
    let input: String
    let fnv1a: UInt32
}

private struct PostalDayCase: Decodable, Sendable {
    let date: String
    let isPostalDay: Bool
    let why: String
}

private struct TransitBandCase: Decodable, Sendable {
    let miles: Double
    let days: Int
}

private struct InternationalBandCase: Decodable, Sendable {
    let countryCode: String
    let min: Int
    let max: Int
}

private struct JitterCase: Decodable, Sendable {
    let messageId: String
    let jitter: Int
}

private struct CollectionCase: Decodable, Sendable {
    let name: String
    let writtenAt: String
    let tz: String
    let postmarkDate: String
    let collectedAt: String
}

private struct ScheduleCase: Decodable, Sendable {
    struct Input: Decodable, Sendable {
        let messageId: String
        let writtenAt: String
        let sender: String
        let recipient: String
    }

    struct Expected: Decodable, Sendable {
        let collectedAt: String
        let postmarkDate: String
        let transitDays: Int
        let deliveryDate: String
        let deliverAt: String
        let isInternational: Bool

        var schedule: Schedule {
            Schedule(
                collectedAt: collectedAt,
                postmarkDate: postmarkDate,
                transitDays: transitDays,
                deliveryDate: deliveryDate,
                deliverAt: deliverAt,
                isInternational: isInternational
            )
        }
    }

    let name: String
    let input: Input
    let expected: Expected
}

private enum FixtureError: Error {
    case missingParty(String)
    case missingUserId
}

private func fixtureData() throws -> Data {
    var fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<5 {
        fixtureURL.deleteLastPathComponent()
    }
    fixtureURL.append(path: "fixtures/mailclock-cases.json")
    return try Data(contentsOf: fixtureURL)
}

private let fixtures = try! JSONDecoder().decode(
    Fixtures.self,
    from: fixtureData()
)

@Test("Fixture document has every contract section and case")
private func fixtureCoverage() throws {
    let document = try #require(
        JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any]
    )
    #expect(
        Set(document.keys) == [
            "$comment",
            "parties",
            "hashVectors",
            "observedHolidays2026",
            "postalDays",
            "transitBands",
            "internationalBands",
            "jitterBranches",
            "collection",
            "schedule",
        ]
    )
    #expect(fixtures.hashVectors.count == 5)
    #expect(fixtures.observedHolidays2026.count == 12)
    #expect(fixtures.parties.count == 7)
    #expect(fixtures.postalDays.count == 11)
    #expect(fixtures.transitBands.count == 10)
    #expect(fixtures.internationalBands.count == 10)
    #expect(fixtures.jitterBranches.count == 6)
    #expect(fixtures.collection.count == 13)
    #expect(fixtures.schedule.count == 18)
    #expect(
        fixtures.hashVectors.count
            + 1
            + fixtures.postalDays.count
            + fixtures.transitBands.count
            + fixtures.internationalBands.count
            + fixtures.jitterBranches.count
            + fixtures.collection.count
            + fixtures.schedule.count == 74
    )
}

@Test("FNV-1a published vectors")
private func hashVectors() {
    var executed = 0
    for testCase in fixtures.hashVectors {
        #expect(fnv1a(testCase.input) == testCase.fnv1a)
        executed += 1
    }
    #expect(executed == fixtures.hashVectors.count)
}

@Test("FNV-1a hashes UTF-16 code units")
private func unicodeHashVectors() {
    let vectors: [(String, UInt32)] = [
        ("é", UInt32(1_812_687_940)),
        ("郵便", UInt32(735_461_629)),
        ("😀", UInt32(3_409_036_472)),
        ("a😀z", UInt32(2_009_751_353)),
    ]
    for (input, expected) in vectors {
        #expect(fnv1a(input) == expected)
    }
}

@Test("Observed holidays for 2026")
private func observedHolidayFixtures() throws {
    #expect(
        try observedHolidays(year: 2026).sorted()
            == fixtures.observedHolidays2026.sorted()
    )
}

@Test("Postal days")
private func postalDayFixtures() throws {
    var executed = 0
    for testCase in fixtures.postalDays {
        #expect(
            try isPostalDay(testCase.date) == testCase.isPostalDay,
            Comment(rawValue: testCase.why)
        )
        executed += 1
    }
    #expect(executed == fixtures.postalDays.count)
}

@Test("Domestic transit bands")
private func transitBandFixtures() {
    let domestic = Party(
        timeZone: "America/New_York",
        latitude: 0,
        longitude: 0,
        countryCode: "US"
    )
    var executed = 0
    for testCase in fixtures.transitBands {
        #expect(
            baseDomesticTransitDays(
                testCase.miles,
                sender: domestic,
                recipient: domestic
            ) == testCase.days
        )
        executed += 1
    }
    #expect(executed == fixtures.transitBands.count)
}

@Test("International transit bands")
private func internationalBandFixtures() {
    var executed = 0
    for testCase in fixtures.internationalBands {
        #expect(
            internationalBand(countryCode: testCase.countryCode)
                == InternationalBand(min: testCase.min, max: testCase.max)
        )
        executed += 1
    }
    #expect(executed == fixtures.internationalBands.count)
}

@Test("Transit jitter branches")
private func jitterFixtures() {
    var executed = 0
    for testCase in fixtures.jitterBranches {
        #expect(transitJitter(messageId: testCase.messageId) == testCase.jitter)
        executed += 1
    }
    #expect(executed == fixtures.jitterBranches.count)
}

@Test("Collection schedules")
private func collectionFixtures() throws {
    var executed = 0
    for testCase in fixtures.collection {
        let result = try nextCollection(
            writtenAt: testCase.writtenAt,
            senderTimeZone: testCase.tz
        )
        #expect(result.postmarkDate == testCase.postmarkDate)
        #expect(result.at == testCase.collectedAt)
        executed += 1
    }
    #expect(executed == fixtures.collection.count)
}

@Test("End-to-end schedules")
private func scheduleFixtures() throws {
    var executed = 0
    for testCase in fixtures.schedule {
        guard let sender = fixtures.parties[testCase.input.sender] else {
            throw FixtureError.missingParty(testCase.input.sender)
        }
        guard let recipient = fixtures.parties[testCase.input.recipient] else {
            throw FixtureError.missingParty(testCase.input.recipient)
        }
        let result = try schedule(
            ScheduleInput(
                messageId: testCase.input.messageId,
                writtenAt: testCase.input.writtenAt,
                sender: sender.party,
                recipient: try recipient.recipient
            )
        )
        #expect(result == testCase.expected.schedule)
        executed += 1
    }
    #expect(executed == fixtures.schedule.count)
}

@Suite("The arrival bundle depends on a single zone")
struct ArrivalZoneDependence {

    /// Asking twice with the same zone tests only what the seed already
    /// guarantees. The property callers need is that they resolved the
    /// recipient's zone once — this is what they get when they didn't.
    @Test("Two zones for one recipient on one date are hours apart")
    func zonesDiverge() throws {
        let east = try carrierArrival(
            userId: "u-moved", localDate: "2026-11-01", timeZone: "America/New_York")
        let west = try carrierArrival(
            userId: "u-moved", localDate: "2026-11-01", timeZone: "America/Los_Angeles")
        #expect(east != west)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let e = try #require(iso.date(from: east))
        let w = try #require(iso.date(from: west))
        #expect(abs(w.timeIntervalSince(e)) == 3 * 3600)

        // The seeded minute itself did not move.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        var west_ = Calendar(identifier: .gregorian)
        west_.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(cal.dateComponents([.hour, .minute], from: e)
            == west_.dateComponents([.hour, .minute], from: w))
    }
}
