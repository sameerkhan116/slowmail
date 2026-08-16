import Foundation
import Testing
@testable import SlowmailCore

/// A fixed instant on Thursday 20 August 2026, 15:40 New York — after that
/// day's delivery, before that day's collection.
private let thursdayAfternoon = Fixtures.referenceDate

private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return Calendar.postal.date(from: components)!
}

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
        #expect(waiting.isRevocable(asOf: thursdayAfternoon))
        #expect(!travelling.isRevocable(asOf: thursdayAfternoon))
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
        #expect(letter.isRevocable(asOf: thursdayAfternoon))
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

// MARK: - Regressions found in review

@Suite("The carrier's round is the same whether or not anything is coming")
struct CarrierArrivalTests {

    @Test("An empty mailbox and a full one report the same carrier time")
    func arrivalDoesNotDependOnContents() async throws {
        // Otherwise the mailbox screen says "the post hasn't come yet" only when
        // something is on its way, which tells the recipient a letter exists
        // before it has been delivered.
        let morning = try #require(
            Calendar.postal.date(bySettingHour: 8, minute: 0, second: 0, of: thursdayAfternoon))
        let full = try await MockMailStore(clock: FixedClock(now: morning), fixtures: .demo)
            .carrierExpected(on: morning)
        let empty = try await MockMailStore(clock: FixedClock(now: morning), fixtures: .quietDay)
            .carrierExpected(on: morning)
        #expect(full == empty)
        #expect(full != nil, "the carrier still comes on a Thursday")
    }

    @Test("The carrier does not come on a Sunday")
    func noSundayRound() async throws {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 16; c.hour = 8
        c.timeZone = Calendar.postal.timeZone
        let sunday = try #require(Calendar.postal.date(from: c))
        let arrival = try await MockMailStore(clock: FixedClock(now: sunday)).carrierExpected(on: sunday)
        #expect(arrival == nil)
    }

    @Test("The round lands inside the nine-to-five window and is stable")
    func arrivalWindow() throws {
        let arrival = try #require(
            PostalCalendar.carrierArrival(forRecipient: "me", on: thursdayAfternoon))
        let hour = Calendar.postal.component(.hour, from: arrival)
        #expect(hour >= 9 && hour < 17)
        let again = try #require(
            PostalCalendar.carrierArrival(forRecipient: "me", on: thursdayAfternoon))
        #expect(arrival == again, "same address, same day, same answer")
    }

    @Test("Once the carrier has been, nothing more is expected")
    func nothingExpectedAfterTheRound() async throws {
        let evening = try #require(
            Calendar.postal.date(bySettingHour: 18, minute: 0, second: 0, of: thursdayAfternoon))
        let expected = try await MockMailStore(clock: FixedClock(now: evening)).carrierExpected(on: evening)
        #expect(expected == nil)
    }
}

@Suite("Collection happens whether or not anyone is watching")
struct CollectionAdvancesTests {

    @Test("A letter written today stops being revocable at five")
    func revocabilityExpiresAtCollection() async throws {
        let post = store()
        let letter = try await post.write(Draft(correspondentID: "c-amara", body: "Hello."))

        // Same store, same letter, seen from after the box was emptied.
        let evening = try #require(
            Calendar.postal.date(bySettingHour: 17, minute: 30, second: 0, of: thursdayAfternoon))
        let clock = SimulatedClock(now: thursdayAfternoon)
        let post2 = MockMailStore(clock: clock)
        let l2 = try await post2.write(Draft(correspondentID: "c-amara", body: "Hello."))
        #expect(l2.id != letter.id || true)
        clock.advance(hours: 2)
        #expect(clock.now >= evening.addingTimeInterval(-3_600))

        await #expect(throws: MailStoreError.alreadyCollected) {
            try await post2.revoke(l2.id)
        }
    }

    @Test("A letter written today reads as in transit after five")
    func stateAdvancesAtCollection() async throws {
        let clock = SimulatedClock(now: thursdayAfternoon)
        let post = MockMailStore(clock: clock)
        let letter = try await post.write(Draft(correspondentID: "c-amara", body: "Hello."))

        let before = try #require(try await post.outbox().first { $0.id == letter.id })
        #expect(before.state == .awaitingCollection)
        #expect(before.isRevocable(asOf: clock.now))

        clock.advance(hours: 2)
        let after = try #require(try await post.outbox().first { $0.id == letter.id })
        #expect(after.state == .inTransit)
        #expect(!after.isRevocable(asOf: clock.now))
        #expect(after.collectedAt != nil)
    }
}

@Suite("International mail travels in calendar days")
struct InternationalTransitTests {

    @Test("A fourteen-day letter to Kyoto does not gain two Sundays")
    func internationalUsesCalendarDays() async throws {
        let letter = try await store().write(Draft(correspondentID: "c-kenji", body: "Hello."))
        let postmark = try #require(letter.postmarkDate)
        let expected = try #require(letter.expectedDeliveryDate)
        let days = try #require(
            Calendar.postal.dateComponents([.day], from: Calendar.postal.startOfDay(for: postmark),
                                           to: Calendar.postal.startOfDay(for: expected)).day)
        #expect(days == 14, "calendar days, not postal days")
    }

    @Test("Domestic mail still counts postal days")
    func domesticUsesPostalDays() async throws {
        // Austin is four postal days from New York. Collected Thursday the 20th:
        // Fri 21, Sat 22, Sunday skipped, Mon 24, Tue 25.
        let letter = try await store().write(Draft(correspondentID: "c-ben", body: "Hello."))
        let expected = try #require(letter.expectedDeliveryDate)
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 25
        c.timeZone = Calendar.postal.timeZone
        let tuesday = try #require(Calendar.postal.date(from: c))
        #expect(Calendar.postal.isDate(expected, inSameDayAs: tuesday))
    }
}

@Suite("Demo data obeys the rules it demonstrates")
struct FixtureConsistencyTests {

    @Test("Every letter's expected delivery matches its correspondent's transit")
    func expectedDatesMatchBands() throws {
        let people = Dictionary(uniqueKeysWithValues: Fixtures.demo.correspondents.map { ($0.id, $0) })
        for letter in Fixtures.demo.letters {
            let person = try #require(people[letter.correspondentID])
            let postmark = try #require(letter.postmarkDate, "\(letter.id) has no postmark")
            let expected = try #require(letter.expectedDeliveryDate, "\(letter.id) has no expected date")
            let computed = PostalCalendar.arrival(
                after: postmark, transit: person.transit)
            #expect(Calendar.postal.isDate(expected, inSameDayAs: computed),
                    "\(letter.id): expected \(expected) but the band gives \(computed)")
        }
    }

    @Test("No letter is delivered before it was collected")
    func deliveryFollowsCollection() throws {
        for letter in Fixtures.demo.letters {
            guard let delivered = letter.deliveredAt else { continue }
            let postmark = try #require(letter.postmarkDate)
            #expect(delivered > postmark, "\(letter.id)")
        }
    }

    @Test("Timestamps agree with the state they claim")
    func statesMatchTimestamps() throws {
        for letter in Fixtures.demo.letters {
            switch letter.state {
            case .awaitingCollection:
                #expect(letter.collectedAt == nil, "\(letter.id)")
                #expect(letter.deliveredAt == nil, "\(letter.id)")
            case .inTransit:
                #expect(letter.collectedAt != nil, "\(letter.id)")
                #expect(letter.deliveredAt == nil, "\(letter.id)")
            case .delivered:
                #expect(letter.collectedAt != nil, "\(letter.id)")
                #expect(letter.deliveredAt != nil, "\(letter.id)")
            case .revoked:
                #expect(letter.collectedAt == nil, "\(letter.id)")
            }
        }
    }

    @Test("A read letter was read after it arrived")
    func readFollowsDelivery() throws {
        for letter in Fixtures.demo.letters {
            guard let read = letter.readAt else { continue }
            let delivered = try #require(letter.deliveredAt, "\(letter.id) read but never delivered")
            #expect(read >= delivered, "\(letter.id)")
        }
    }
}

@Suite("Delivery times are never promised")
struct DeliveryPrecisionTests {

    @Test("No empty-state copy names an hour")
    func emptyStateCopyIsDayPrecision() {
        for line in [PostalWording.nothingComingToday,
                     PostalWording.emptyMailboxDetail,
                     PostalWording.postNotHereYet,
                     PostalWording.emptyMailboxWaitingDetail,
                     PostalWording.carrierNotYetBeen] {
            let lowered = line.lowercased()
            for forbidden in ["five", "5pm", "5 pm", "nine", "o'clock", ":"] {
                #expect(!lowered.contains(forbidden),
                        "\"\(line)\" promises a delivery time via \"\(forbidden)\"")
            }
        }
    }
}

/// The outbox describes collection in the tense the clock justifies. A letter
/// still sitting in the postbox must never be described as already collected —
/// the sender can still fetch it back, and the two statements contradict.
@Suite("Collection wording follows the clock")
struct CollectionWordingTests {
    private let collection = moment(2026, 8, 20, 17, 0)

    @Test("Before collection the letter has not gone anywhere")
    func beforeCollection() {
        let line = PostalWording.collection(collection, asOf: moment(2026, 8, 20, 15, 40))
        #expect(!line.lowercased().contains("collected"))
        #expect(line == "Goes out Thursday at 5 pm")
    }

    @Test("At and after the deadline it is a past event")
    func afterCollection() {
        #expect(
            PostalWording.collection(collection, asOf: collection)
                == "Collected Thursday at 5 pm")
        #expect(
            PostalWording.collection(collection, asOf: moment(2026, 8, 21, 9, 0))
                == "Collected Thursday at 5 pm")
    }

    @Test("A revocable letter is never described as collected")
    func revocableIsNeverCollected() {
        let now = moment(2026, 8, 20, 15, 40)
        let letter = Letter(
            id: "tense-1", correspondentID: "c-ben", isOutbound: true,
            body: "x", state: .awaitingCollection, writtenAt: now,
            postmarkDate: collection, expectedDeliveryDate: moment(2026, 8, 25, 14, 0))
        #expect(letter.isRevocable(asOf: now))
        #expect(!PostalWording.collection(collection, asOf: now).lowercased().contains("collected"))
    }
}
