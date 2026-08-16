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

private func loadFixtures() throws -> Fixtures {
    var fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<5 {
        fixtureURL.deleteLastPathComponent()
    }
    fixtureURL.append(path: "fixtures/mailclock-cases.json")
    return try JSONDecoder().decode(
        Fixtures.self,
        from: Data(contentsOf: fixtureURL)
    )
}

private let fixtures = try! loadFixtures()

@Test("FNV-1a published vector", arguments: fixtures.hashVectors)
private func hashVector(_ testCase: HashVector) {
    #expect(fnv1a(testCase.input) == testCase.fnv1a)
}

@Test(
    "FNV-1a hashes UTF-16 code units",
    arguments: [
        ("é", UInt32(1_812_687_940)),
        ("郵便", UInt32(735_461_629)),
        ("😀", UInt32(3_409_036_472)),
        ("a😀z", UInt32(2_009_751_353)),
    ]
)
private func unicodeHashVector(_ input: String, _ expected: UInt32) {
    #expect(fnv1a(input) == expected)
}

@Test("Observed holidays for 2026")
private func observedHolidayFixtures() throws {
    #expect(
        try observedHolidays(year: 2026).sorted()
            == fixtures.observedHolidays2026.sorted()
    )
}

@Test("Postal day", arguments: fixtures.postalDays)
private func postalDayFixture(_ testCase: PostalDayCase) throws {
    #expect(
        try isPostalDay(testCase.date) == testCase.isPostalDay,
        Comment(rawValue: testCase.why)
    )
}

@Test("Domestic transit band", arguments: fixtures.transitBands)
private func transitBandFixture(_ testCase: TransitBandCase) {
    let domestic = Party(
        timeZone: "America/New_York",
        latitude: 0,
        longitude: 0,
        countryCode: "US"
    )
    #expect(
        baseDomesticTransitDays(
            testCase.miles,
            sender: domestic,
            recipient: domestic
        ) == testCase.days
    )
}

@Test("International transit band", arguments: fixtures.internationalBands)
private func internationalBandFixture(_ testCase: InternationalBandCase) {
    #expect(
        internationalBand(countryCode: testCase.countryCode)
            == InternationalBand(min: testCase.min, max: testCase.max)
    )
}

@Test("Transit jitter branch", arguments: fixtures.jitterBranches)
private func jitterFixture(_ testCase: JitterCase) {
    #expect(transitJitter(messageId: testCase.messageId) == testCase.jitter)
}

@Test("Collection schedule", arguments: fixtures.collection)
private func collectionFixture(_ testCase: CollectionCase) throws {
    let result = try nextCollection(
        writtenAt: testCase.writtenAt,
        senderTimeZone: testCase.tz
    )
    #expect(result.postmarkDate == testCase.postmarkDate)
    #expect(result.at == testCase.collectedAt)
}

@Test("End-to-end schedule", arguments: fixtures.schedule)
private func scheduleFixture(_ testCase: ScheduleCase) throws {
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
}
