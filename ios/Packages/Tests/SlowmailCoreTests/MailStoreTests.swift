import Foundation
import Testing
@testable import SlowmailCore
@testable import SlowmailUI
import MailClockKit

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

/// A moment on the reference day before the carrier reaches "me". Derived from
/// the round rather than typed, so it stays "before delivery" if the seed moves.
private let beforeTheRound: Date = {
    let round = PostalCalendar.carrierArrival(
        forRecipient: Fixtures.userID, on: thursdayAfternoon) ?? thursdayAfternoon
    return round.addingTimeInterval(-60)
}()

private func store(at date: Date = thursdayAfternoon) -> MockMailStore {
    MockMailStore(clock: FixedClock(now: date))
}

@Suite("The post office withholds what hasn't arrived")
struct DeliveryVisibilityTests {

    @Test("A letter is invisible until its delivery instant")
    func inboundHiddenBeforeDelivery() async throws {
        // A minute before the carrier reaches this address, the letters they
        // are carrying do not exist as far as the recipient is concerned.
        let mailbox = try await store(at: beforeTheRound).mailbox()
        #expect(mailbox.isEmpty)

        let later = try await store().mailbox()
        #expect(later.contains { $0.id == "l-002" })
    }

    @Test("Correspondence never leaks an inbound letter that hasn't landed")
    func correspondenceHidesUndelivered() async throws {
        let thread = try await store(at: beforeTheRound).correspondence(with: "c-ben")
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
        // Asking twice with the same instant would compare a value to itself.
        // The claim is that any moment of the same local day gives one answer.
        let dawn = try #require(
            Calendar.postal.date(bySettingHour: 0, minute: 1, second: 0, of: thursdayAfternoon))
        let dusk = try #require(
            Calendar.postal.date(bySettingHour: 23, minute: 59, second: 0, of: thursdayAfternoon))
        for instant in [dawn, dusk] {
            let again = try #require(
                PostalCalendar.carrierArrival(forRecipient: "me", on: instant))
            #expect(arrival == again, "same address, same day, same answer")
        }
        // And a different address on the same day must not share the round.
        let other = try #require(
            PostalCalendar.carrierArrival(forRecipient: "someone-else", on: thursdayAfternoon))
        #expect(other != arrival)
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
        // Five o'clock exactly is the collection, not the last moment before
        // it. Testing from half past would pass whether the comparison is
        // strict or not, which is the whole question.
        let clock = SimulatedClock(now: thursdayAfternoon)
        let post = MockMailStore(clock: clock)
        let letter = try await post.write(Draft(correspondentID: "c-amara", body: "Hello."))
        let collection = try #require(letter.postmarkDate)

        clock.set(collection.addingTimeInterval(-1))
        #expect(letter.isRevocable(asOf: clock.now), "a second before, it is still yours")
        try await post.revoke(letter.id)

        let clock2 = SimulatedClock(now: thursdayAfternoon)
        let post2 = MockMailStore(clock: clock2)
        let l2 = try await post2.write(Draft(correspondentID: "c-amara", body: "Hello."))
        clock2.set(try #require(l2.postmarkDate))
        #expect(!l2.isRevocable(asOf: clock2.now), "at five it has gone")
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

    @Test("A calendar-day arrival landing on a Sunday waits for Monday")
    func calendarArrivalRollsOffSunday() throws {
        // Thursday 20 August plus fourteen never lands on a Sunday, so the
        // fourteen-day case above cannot exercise the roll-forward at all.
        // Ten days from the same Thursday is Sunday 30 August.
        let collection = try #require(
            Calendar.postal.date(bySettingHour: 17, minute: 0, second: 0, of: thursdayAfternoon))
        let naive = try #require(
            Calendar.postal.date(byAdding: .day, value: 10, to: collection))
        #expect(Calendar.postal.component(.weekday, from: naive) == 1, "the setup must hit a Sunday")

        let arrival = PostalCalendar.arrival(after: collection, transit: .international(10))
        #expect(Calendar.postal.component(.weekday, from: arrival) == 2, "carried to Monday")
        #expect(Calendar.postal.isDate(
            arrival, inSameDayAs: try #require(
                Calendar.postal.date(byAdding: .day, value: 1, to: naive))))
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
            let transit = try #require(person.transit, "\(person.name) has no address")
            let computed = PostalCalendar.arrival(after: postmark, transit: transit)
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

/// The client shows the carrier's round without asking the server, which only
/// works while both compute the same seed from the same inputs. These vectors
/// come from running `carrierArrival` in `packages/mailclock` — the engine that
/// actually decides delivery — so a divergence in namespace, quantisation or
/// local-time construction fails here instead of silently telling one person
/// the post has been when it has not.
///
/// They are compared as local wall-clock times rather than absolute instants,
/// and that is deliberate. The seed determines a local hour and minute; which
/// UTC instant that denotes is a fact about the zone's history, and the two
/// runtimes do not always agree on it. Egypt is the live example: Swift carries
/// tzdata 2026c and puts Cairo at UTC+3 on 2025-04-25, while Node's bundled ICU
/// still has UTC+2. Both agree the carrier comes at 11:05 local; they disagree
/// by an hour about what that means in UTC. Asserting the instant here would
/// fail on a difference this code cannot cause and cannot fix.
@Suite("The client's round agrees with the scheduling engine")
struct CarrierArrivalGoldenVectors {
    private struct Vector {
        let userID: String
        let localDate: String
        let zone: String
        let localTime: String
    }

    private let vectors = [
        Vector(userID: "me", localDate: "2026-08-20", zone: "America/New_York", localTime: "12:23"),
        Vector(userID: "me", localDate: "2026-08-21", zone: "America/New_York", localTime: "09:24"),
        Vector(userID: "someone-else", localDate: "2026-08-20", zone: "America/New_York",
               localTime: "15:35"),
        // Cairo's clocks jump at midnight on this date, so the day begins at
        // 01:00 and adding elapsed seconds to its start overshoots the window.
        Vector(userID: "user-0", localDate: "2025-04-25", zone: "Africa/Cairo", localTime: "11:05"),
        // Non-ASCII: agrees only if both sides hash UTF-16 code units.
        Vector(userID: "ünïcodé", localDate: "2026-12-24", zone: "Asia/Tokyo", localTime: "14:12"),
    ]

    @Test("Every vector reproduces the engine's local time exactly")
    func matchesEngine() throws {
        for vector in vectors {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: vector.zone))
            var parts = DateComponents()
            let numbers = vector.localDate.split(separator: "-").map { Int($0)! }
            parts.year = numbers[0]
            parts.month = numbers[1]
            parts.day = numbers[2]
            parts.hour = 12
            let noon = try #require(calendar.date(from: parts))

            let arrival = try #require(
                PostalCalendar.carrierArrival(
                    forRecipient: vector.userID, on: noon, calendar: calendar))
            let fields = calendar.dateComponents([.hour, .minute], from: arrival)
            let actual = String(format: "%02d:%02d", fields.hour ?? -1, fields.minute ?? -1)
            #expect(
                actual == vector.localTime,
                "\(vector.userID) on \(vector.localDate) in \(vector.zone)")

            let hour = try #require(fields.hour)
            #expect(hour >= 9 && hour < 17, "the round stays inside the working day")

            // The arrival must fall on the day it was drawn for, which adding
            // elapsed seconds to a short or long day does not guarantee.
            #expect(calendar.isDate(arrival, inSameDayAs: noon))
        }
    }
}

/// The invariant, pinned rather than left to review: nothing the app says about
/// a *particular* letter carries a clock time. Collection is exempt by design —
/// it is a deadline the sender acts on, not a prediction about arrival.
@Suite("No letter is ever given a time of day")
struct DeliveryPrecisionInvariant {

    @Test("Arrival wording across a year of dates names days, never hours")
    func arrivalWordingHasNoClockTimes() throws {
        let clockish = try NSRegularExpression(pattern: #"\d{1,2}[:.]\d{2}|\b\d{1,2}\s?(am|pm)\b"#,
                                               options: .caseInsensitive)
        var day = Fixtures.referenceDate
        for _ in 0..<365 {
            // arrivedOn(day, now: day) always takes the "today" branch, so
            // the dated branch — the one that formats — would never be seen.
            let laterOn = Calendar.postal.date(byAdding: .day, value: 4, to: day) ?? day
            let lines = [
                PostalWording.expectedArrival(day),
                PostalWording.arrivedOn(day, now: day),
                PostalWording.arrivedOn(day, now: laterOn),
                PostalWording.postmark(day),
            ]
            for line in lines {
                let range = NSRange(line.startIndex..., in: line)
                #expect(
                    clockish.firstMatch(in: line, range: range) == nil,
                    "arrival copy must not name a time: \(line)")
            }
            day = try #require(Calendar.postal.date(byAdding: .day, value: 1, to: day))
        }
    }

    @Test("Collection is the one place a time appears, and it is a deadline")
    func collectionStatesItsDeadline() {
        let five = Fixtures.referenceDate.addingTimeInterval(3_600)
        let line = PostalWording.collection(five, asOf: Fixtures.referenceDate)
        #expect(line.contains("5 pm") || line.contains("4 pm"))
    }
}

/// Exact parity with the engine's hash, not merely parity modulo the arrival
/// window. Carrier times observe `seeded(...) % 480`, so adding 480 to every
/// hash would leave all five arrival vectors unchanged while breaking every
/// other seeded draw. These pin the values themselves.
@Suite("Seeded hashing matches the engine exactly")
struct SeededHashGoldenVectors {

    @Test("FNV-1a over UTF-16 code units")
    func rawHash() {
        let vectors: [(String, UInt32)] = [
            ("", 2_166_136_261),
            ("a", 3_826_002_220),
            ("hello", 1_335_831_723),
            ("ünïcodé", 592_457_729),
            ("letter-0010", 3_472_029_081),
            ("me", 1_747_856_039),
        ]
        for (input, expected) in vectors {
            #expect(MailClockKit.fnv1a(input) == expected, "fnv1a(\(input))")
        }
    }

    @Test("Namespaced hash, unit interval and inclusive range")
    func namespacedDraws() {
        let vectors: [(String, [String], UInt32, Double, Int)] = [
            ("carrier-arrival", ["me", "2026-08-20"], 2_217_630_923, 0.516_332_435_188_815, 203),
            ("transit-jitter", ["letter-0010"], 2_970_219_823, 0.691_558_193_182_572_7, 463),
            ("carrier-arrival", ["ünïcodé", "2026-12-24"], 1_297_938_072, 0.302_199_756_726_622_58, 312),
            ("arrival", ["me", "2026-08-20"], 414_333_630, 0.096_469_565_760_344_27, 30),
        ]
        for (namespace, parts, hash, unit, ranged) in vectors {
            #expect(MailClockKit.seededHashParts(namespace: namespace, parts: parts) == hash, "seededHash(\(namespace))")
            let actualUnit = MailClockKit.seededUnitParts(namespace: namespace, parts: parts)
            #expect(abs(actualUnit - unit) < 1e-15, "seededUnit(\(namespace)) = \(actualUnit)")
            #expect(
                (try? MailClockKit.seededIntInRange(min: 0, max: 479, namespace: namespace, parts: parts)) == ranged,
                "seededIntInRange(\(namespace))")
        }
    }
}

/// Everything that lands on one day lands together, because one carrier walks
/// one round. A fixture with its own plausible-looking delivery time breaks
/// that: the mailbox reports the carrier has been, then more mail appears.
@Suite("Delivered mail arrives on its recipient's round")
struct DeliveryMatchesTheRound {

    @Test("Every delivered fixture matches the round for its day")
    func deliveriesAreOnTheRound() throws {
        let inbound = Fixtures.demo.letters.filter { !$0.isOutbound }
        #expect(!inbound.isEmpty)
        for letter in inbound {
            guard let delivered = letter.deliveredAt else { continue }
            let round = try #require(
                PostalCalendar.carrierArrival(forRecipient: Fixtures.userID, on: delivered))
            #expect(delivered == round, "letter \(letter.id) arrived off its round")
        }
    }

    @Test("Nothing arrives after the carrier has been")
    func nothingArrivesAfterTheRound() async throws {
        // The screens are rendered mid-afternoon, after the round. If a fixture
        // is timed later than the round, the mailbox says the post has come and
        // then quietly grows.
        let store = MockMailStore(clock: FixedClock(now: Fixtures.referenceDate))
        let expected = try await store.carrierExpected(on: Fixtures.referenceDate)
        #expect(expected == nil, "the round is already over at the reference instant")

        let today = try await store.mailbox().filter {
            $0.deliveredAt.map { Calendar.postal.isDate($0, inSameDayAs: Fixtures.referenceDate) }
                ?? false
        }
        for letter in today {
            let delivered = try #require(letter.deliveredAt)
            #expect(delivered <= Fixtures.referenceDate, "letter \(letter.id) is still to come")
        }
    }
}

/// The client's idea of when the round happened is an estimate that can run
/// ahead of the server's by up to an hour, so no copy may declare the day over.
@Suite("The mailbox never forecloses the day")
struct EmptyStateHonesty {

    @Test("Empty-state copy makes no claim about what was posted")
    func emptyStateClaimsNothing() {
        let foreclosing = ["nothing was posted", "no one wrote", "nothing came",
                           "nothing for you today", "no letters were sent", "no mail"]
        for line in [PostalWording.emptyMailboxDetail, PostalWording.emptyMailboxWaitingDetail,
                     PostalWording.nothingComingToday] {
            let lowered = line.lowercased()
            for phrase in foreclosing {
                #expect(!lowered.contains(phrase), "\"\(line)\" claims the day is finished")
            }
        }
    }
}

/// The client works out the round from its own timezone database, which can put
/// it up to an hour ahead of the server's. A mailbox left open must keep looking
/// through that window, or it stops watching just before the mail lands.
@Suite("Watching continues through the skew window")
@MainActor
struct RoundSkewWindow {

    @Test("The app keeps checking after it believes the round has been")
    func watchesPastTheRound() async throws {
        let round = try #require(
            PostalCalendar.carrierArrival(forRecipient: Fixtures.userID, on: thursdayAfternoon))
        let justAfter = round.addingTimeInterval(60)
        let model = AppModel(
            store: MockMailStore(clock: FixedClock(now: justAfter)),
            clock: FixedClock(now: justAfter))
        await model.load()

        #expect(model.carrierExpected == nil, "the round is over by the client's reckoning")
        let boundary = try #require(model.nextBoundary)
        let collection = PostalCalendar.nextCollection(after: justAfter)
        #expect(boundary < collection, "waiting for collection would miss a late delivery")
        #expect(boundary <= round.addingTimeInterval(PostalCalendar.maximumRoundSkew))
    }

    @Test("Once the window has passed it waits for collection")
    func settlesAfterTheWindow() async throws {
        let round = try #require(
            PostalCalendar.carrierArrival(forRecipient: Fixtures.userID, on: thursdayAfternoon))
        let settled = round.addingTimeInterval(PostalCalendar.maximumRoundSkew + 60)
        let model = AppModel(
            store: MockMailStore(clock: FixedClock(now: settled)),
            clock: FixedClock(now: settled))
        await model.load()
        #expect(model.nextBoundary == PostalCalendar.nextCollection(after: settled))
    }
}

/// Posting is asynchronous and the composer can be closed and reopened while a
/// letter is in flight. Matching on the text alone cannot tell that apart from
/// someone retyping the same reply, and gets it wrong in both directions.
@Suite("A draft is owned by the session that wrote it")
struct DraftLedgerTests {

    @Test("The ordinary path clears the draft and closes the sheet")
    func ordinaryPost() {
        var ledger = DraftLedger()
        ledger.openComposer()
        ledger.setBody("Dear Ben", for: "c-ben")
        let sent = ledger.currentGeneration
        let closed = ledger.completePost(of: "Dear Ben", to: "c-ben", sentUnder: sent)
        #expect(closed)
        #expect(ledger.body(for: "c-ben").isEmpty)
    }

    @Test("Closing the sheet without reopening still tidies up")
    func closedButNotReopened() {
        var ledger = DraftLedger()
        ledger.openComposer()
        ledger.setBody("Dear Ben", for: "c-ben")
        let sent = ledger.currentGeneration
        // The sender dismissed the sheet; no new session began.
        let closed = ledger.completePost(of: "Dear Ben", to: "c-ben", sentUnder: sent)
        #expect(closed)
        #expect(ledger.body(for: "c-ben").isEmpty)
    }

    @Test("Reopening keeps what the sender is typing now")
    func reopenedKeepsLiveTyping() {
        var ledger = DraftLedger()
        ledger.openComposer()
        ledger.setBody("Dear Ben", for: "c-ben")
        let sent = ledger.currentGeneration
        ledger.openComposer()
        ledger.setBody("Actually, something else", for: "c-ben")
        let closed = ledger.completePost(of: "Dear Ben", to: "c-ben", sentUnder: sent)
        #expect(!closed)
        #expect(ledger.body(for: "c-ben") == "Actually, something else")
        #expect(ledger.canPost("c-ben"))
    }

    @Test("The same words cannot be posted twice")
    func strandedTextCannotBeResent() {
        var ledger = DraftLedger()
        ledger.openComposer()
        ledger.setBody("Dear Ben", for: "c-ben")
        let sent = ledger.currentGeneration
        // Dismissed and reopened while the post was in flight, so the text that
        // went out is still sitting in the box.
        ledger.openComposer()
        let closed = ledger.completePost(of: "Dear Ben", to: "c-ben", sentUnder: sent)
        #expect(!closed)
        #expect(ledger.body(for: "c-ben") == "Dear Ben")
        #expect(ledger.isAlreadyPosted("c-ben"))
        #expect(!ledger.canPost("c-ben"), "posting again would send a duplicate")
    }

    @Test("Changing a word makes it a new letter")
    func editingClearsTheDuplicateBlock() {
        var ledger = DraftLedger()
        ledger.openComposer()
        ledger.setBody("Dear Ben", for: "c-ben")
        let sent = ledger.currentGeneration
        ledger.openComposer()
        ledger.completePost(of: "Dear Ben", to: "c-ben", sentUnder: sent)
        #expect(!ledger.canPost("c-ben"))
        ledger.setBody("Dear Ben,", for: "c-ben")
        #expect(ledger.canPost("c-ben"))
    }

    @Test("Blank drafts are not postable")
    func blankIsNotPostable() {
        var ledger = DraftLedger()
        ledger.openComposer()
        ledger.setBody("   \n ", for: "c-ben")
        #expect(!ledger.canPost("c-ben"))
    }
}
