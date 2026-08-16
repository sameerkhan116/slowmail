import Foundation
import Testing
@testable import SlowmailCore

/// A fixed instant on Thursday 20 August 2026, 15:40 New York — after that
/// day's delivery, before that day's collection.
private let thursdayAfternoon = Fixtures.referenceDate

private func store(at date: Date = thursdayAfternoon) -> MockMailStore {
    MockMailStore(clock: FixedClock(now: date))
}

@Suite("The post office withholds what hasn't arrived")
struct DeliveryVisibilityTests {

    @Test("A letter is invisible until its delivery instant")
    func inboundHiddenBeforeDelivery() async throws {
        // Nour's letter is delivered at 13:27 on the 20th. An hour earlier it
        // does not exist as far as the recipient is concerned.
        let early = try #require(Calendar.postal.date(byAdding: .hour, value: -3, to: thursdayAfternoon))
        let mailbox = try await store(at: early).mailbox()
        #expect(mailbox.isEmpty)

        let later = try await store().mailbox()
        #expect(later.contains { $0.id == "l-002" })
    }

    @Test("Correspondence never leaks an inbound letter that hasn't landed")
    func correspondenceHidesUndelivered() async throws {
        let early = try #require(Calendar.postal.date(byAdding: .hour, value: -3, to: thursdayAfternoon))
        let thread = try await store(at: early).correspondence(with: "c-ben")
        #expect(!thread.contains { $0.id == "l-001" })
        // Your own outbound letters remain visible; they are yours.
        #expect(thread.contains { $0.id == "l-005" })
    }

    @Test("The mailbox holds today's round plus anything still unopened")
    func mailboxScope() async throws {
        let mailbox = try await store().mailbox()
        let ids = Set(mailbox.map(\.id))
        #expect(ids.contains("l-001"))
        #expect(ids.contains("l-002"))
        // Read on the 10th and the 18th — out of the box already.
        #expect(!ids.contains("l-003"))
        #expect(!ids.contains("l-004"))
    }

    @Test("An unread letter from an earlier round stays in the box")
    func unreadPersists() async throws {
        let nextWeek = try #require(Calendar.postal.date(byAdding: .day, value: 5, to: thursdayAfternoon))
        let mailbox = try await store(at: nextWeek).mailbox()
        #expect(mailbox.contains { $0.id == "l-001" }, "still unread five days on")
    }
}

@Suite("Collection is the point of no return")
struct RevocationTests {

    @Test("A letter waiting for collection can be fetched back")
    func revokeBeforeCollection() async throws {
        let post = store()
        try await post.revoke("l-005")
        let outbox = try await post.outbox()
        #expect(!outbox.contains { $0.id == "l-005" })
    }

    @Test("A letter the carrier already has cannot be fetched back")
    func revokeAfterCollection() async throws {
        let post = store()
        await #expect(throws: MailStoreError.alreadyCollected) {
            try await post.revoke("l-006")
        }
        let outbox = try await post.outbox()
        #expect(outbox.contains { $0.id == "l-006" }, "it is still on its way")
    }

    @Test("Revoking twice fails the second time")
    func revokeIsNotIdempotent() async throws {
        let post = store()
        try await post.revoke("l-005")
        await #expect(throws: MailStoreError.alreadyCollected) {
            try await post.revoke("l-005")
        }
    }

    @Test("Only letters awaiting collection advertise themselves as revocable")
    func revocableFlag() async throws {
        let outbox = try await store().outbox()
        let waiting = try #require(outbox.first { $0.id == "l-005" })
        let travelling = try #require(outbox.first { $0.id == "l-006" })
        #expect(waiting.isRevocable)
        #expect(!travelling.isRevocable)
    }
}

@Suite("Writing a letter")
struct WritingTests {

    @Test("A posted letter waits for the next collection")
    func postedLetterAwaitsCollection() async throws {
        let post = store()
        let letter = try await post.write(Draft(correspondentID: "c-amara", body: "Hello."))
        #expect(letter.state == .awaitingCollection)
        #expect(letter.collectedAt == nil)
        #expect(letter.isRevocable)
    }

    @Test("Written before five, collected the same day")
    func sameDayCollection() async throws {
        let letter = try await store().write(Draft(correspondentID: "c-amara", body: "Hello."))
        let postmark = try #require(letter.postmarkDate)
        #expect(Calendar.postal.isDate(postmark, inSameDayAs: thursdayAfternoon))
        #expect(Calendar.postal.component(.hour, from: postmark) == 17)
    }

    @Test("Written after five, collected tomorrow")
    func nextDayCollection() async throws {
        let evening = try #require(
            Calendar.postal.date(bySettingHour: 18, minute: 30, second: 0, of: thursdayAfternoon))
        let letter = try await store(at: evening).write(Draft(correspondentID: "c-amara", body: "Hello."))
        let postmark = try #require(letter.postmarkDate)
        let friday = try #require(Calendar.postal.date(byAdding: .day, value: 1, to: thursdayAfternoon))
        #expect(Calendar.postal.isDate(postmark, inSameDayAs: friday))
    }

    @Test("An empty letter is refused")
    func emptyBodyRefused() async throws {
        let post = store()
        await #expect(throws: MailStoreError.emptyBody) {
            try await post.write(Draft(correspondentID: "c-amara", body: "   \n  "))
        }
    }

    @Test("A letter to nobody is refused")
    func unknownRecipientRefused() async throws {
        let post = store()
        await #expect(throws: MailStoreError.unknownCorrespondent("c-nobody")) {
            try await post.write(Draft(correspondentID: "c-nobody", body: "Hello."))
        }
    }

    @Test("Marking read is recorded once and then left alone")
    func markReadIsStable() async throws {
        let post = store()
        try await post.markRead("l-001")
        let first = try #require(try await post.mailbox().first { $0.id == "l-001" })
        let stamp = try #require(first.readAt)
        try await post.markRead("l-001")
        let second = try #require(try await post.correspondence(with: "c-ben").first { $0.id == "l-001" })
        #expect(second.readAt == stamp)
    }
}

@Suite("Postal days")
struct PostalCalendarTests {

    private func day(_ month: Int, _ day: Int, hour: Int = 9) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = month; c.day = day; c.hour = hour
        c.timeZone = Calendar.postal.timeZone
        return Calendar.postal.date(from: c)!
    }

    @Test("Sunday is not a postal day; every other day is")
    func sundayOff() {
        // 16 August 2026 is a Sunday.
        #expect(!PostalCalendar.isPostalDay(day(8, 16)))
        for offset in 1...6 {
            let d = Calendar.postal.date(byAdding: .day, value: offset, to: day(8, 16))!
            #expect(PostalCalendar.isPostalDay(d), "day \(offset) after Sunday")
        }
    }

    @Test("Nothing is collected on a Sunday")
    func sundayCollectionRollsForward() {
        let collection = PostalCalendar.nextCollection(after: day(8, 16, hour: 10))
        #expect(Calendar.postal.component(.weekday, from: collection) == 2, "Monday")
        #expect(Calendar.postal.component(.hour, from: collection) == 17)
    }

    @Test("Five o'clock is the deadline, not a grace period")
    func cutoffIsExclusive() {
        let atFive = PostalCalendar.nextCollection(after: day(8, 20, hour: 17))
        #expect(Calendar.postal.isDate(atFive, inSameDayAs: day(8, 21)), "17:00 has missed it")

        let justBefore = PostalCalendar.nextCollection(after: day(8, 20, hour: 16))
        #expect(Calendar.postal.isDate(justBefore, inSameDayAs: day(8, 20)))
    }

    @Test("Transit counts postal days, skipping Sundays")
    func transitSkipsSundays() {
        // Friday 21st + 3 postal days = Sat 22, (Sun skipped), Mon 24, Tue 25.
        let arrival = PostalCalendar.addingPostalDays(3, to: day(8, 21))
        #expect(Calendar.postal.isDate(arrival, inSameDayAs: day(8, 25)))
    }

    @Test("Zero transit days leaves the date alone")
    func zeroTransit() {
        let same = PostalCalendar.addingPostalDays(0, to: day(8, 21))
        #expect(same == day(8, 21))
    }
}

@Suite("How the app talks about time")
struct WordingTests {

    @Test("Arrival is described in days, never in minutes")
    func arrivalWording() {
        let now = thursdayAfternoon
        let yesterday = Calendar.postal.date(byAdding: .day, value: -1, to: now)!
        let lastWeek = Calendar.postal.date(byAdding: .day, value: -6, to: now)!

        #expect(PostalWording.arrivedOn(now, now: now) == "Arrived today")
        #expect(PostalWording.arrivedOn(yesterday, now: now) == "Arrived yesterday")

        let older = PostalWording.arrivedOn(lastWeek, now: now)
        #expect(older.hasPrefix("Arrived "))
        #expect(!older.contains(":"), "no clock time in an arrival line")
    }

    @Test("An expected arrival names a day, never a time")
    func expectedWording() {
        let line = PostalWording.expectedArrival(thursdayAfternoon)
        #expect(line == "Should arrive around Thursday 20 August")
        #expect(!line.contains(":"))
    }

    @Test("Distance reads as prose")
    func distanceWording() {
        #expect(PostalWording.distance(miles: 1) == "1 mile away")
        #expect(PostalWording.distance(miles: 1510) == "1,510 miles away")
    }
}
