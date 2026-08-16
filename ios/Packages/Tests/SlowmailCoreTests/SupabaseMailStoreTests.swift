import Foundation
import Testing
@testable import SlowmailCore

/// Records what was asked of the network and answers with whatever the test
/// wants, so request shape and decoding are checked without one.
private actor RecordingTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var replies: [String: (Int, String)] = [:]
    private let fallback: (Int, String)

    init(fallback: (Int, String) = (200, "[]")) {
        self.fallback = fallback
    }

    func reply(to rpc: String, status: Int = 200, body: String) {
        replies[rpc] = (status, body)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let name = request.url?.lastPathComponent ?? ""
        let (status, body) = replies[name] ?? fallback
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }
    var headers: [[String: String]] { requests.map { $0.allHTTPHeaderFields ?? [:] } }
}

private struct StubTokens: TokenProvider {
    let token: String
    let id: CorrespondentID
    func accessToken() async throws -> String { token }
    var userID: CorrespondentID { get async { id } }
}

private func makeStore(
    _ transport: RecordingTransport,
    me: CorrespondentID = "me-uuid",
    now: Date = Fixtures.referenceDate
) -> SupabaseMailStore {
    SupabaseMailStore(
        baseURL: URL(string: "https://example.supabase.co")!,
        apiKey: "anon-key",
        tokens: StubTokens(token: "jwt-abc", id: me),
        clock: FixedClock(now: now),
        transport: transport
    )
}

/// A row as Postgres actually renders it: snake_case, fractional seconds on
/// timestamptz, a bare date on `postmark_date`.
private let deliveredRow = """
[{"id":"l-1","sender_id":"them-uuid","recipient_id":"me-uuid","body":"Hello",
  "state":"delivered","written_at":"2026-08-15T15:00:00.000Z",
  "collected_at":"2026-08-15T21:00:00.000Z","postmark_date":"2026-08-15",
  "deliver_at":"2026-07-23T21:06:00.000Z","delivered_at":"2026-08-20T16:23:00.000Z",
  "read_at":null}]
"""

@Suite("The client reaches the post office only through its functions")
struct SupabaseTransportTests {

    @Test("Reads go to RPCs, never to the letters table")
    func neverTouchesTheTable() async throws {
        let transport = RecordingTransport()
        let store = makeStore(transport)
        _ = try await store.mailbox()
        _ = try await store.outbox()
        _ = try await store.correspondence(with: "them-uuid")

        let paths = await transport.paths
        #expect(paths.count == 3)
        for path in paths {
            #expect(path.hasPrefix("/rest/v1/rpc/"), "\(path) is not a function call")
            // The table isn't merely unused — it is unreadable, because
            // PostgREST will count rows the caller cannot see and a count of
            // undelivered letters is itself the letter.
            #expect(!path.contains("/rest/v1/letters"))
        }
        #expect(paths == [
            "/rest/v1/rpc/mailbox",
            "/rest/v1/rpc/outbox",
            "/rest/v1/rpc/correspondence",
        ])
    }

    @Test("No request ever asks for a count")
    func neverAsksForACount() async throws {
        let transport = RecordingTransport()
        let store = makeStore(transport)
        _ = try await store.mailbox()
        _ = try? await store.write(Draft(correspondentID: "them-uuid", body: "Hi"))
        try? await store.markRead("l-1")

        for header in await transport.headers {
            let prefer = (header["Prefer"] ?? header["prefer"]) ?? ""
            #expect(!prefer.contains("count"), "asked for a count: \(prefer)")
        }
    }

    @Test("Every request carries the caller's identity and the key")
    func alwaysAuthenticated() async throws {
        let transport = RecordingTransport()
        let store = makeStore(transport)
        _ = try await store.mailbox()
        try? await store.revoke("l-1")

        let headers = await transport.headers
        #expect(headers.count == 2)
        for header in headers {
            #expect(header["Authorization"] == "Bearer jwt-abc")
            #expect(header["apikey"] == "anon-key")
        }
    }
}

/// A letter that has been opened. Every other fixture leaves `read_at` null,
/// which meant its key could be misspelled and nothing would notice — absent
/// and wrongly-named both decode to nil.
private let readRow = """
[{"id":"l-2","sender_id":"them-uuid","recipient_id":"me-uuid","body":"Read me",
  "state":"delivered","written_at":"2026-08-10T15:00:00+00:00",
  "collected_at":"2026-08-10T21:00:00+00:00","postmark_date":"2026-08-10",
  "deliver_at":"2026-08-14T16:23:00+00:00","delivered_at":"2026-08-14T16:23:00+00:00",
  "read_at":"2026-08-14T18:05:00+00:00"}]
"""

@Suite("Rows decode the way Postgres renders them")
struct SupabaseDecodingTests {

    @Test("A delivered letter round-trips with its milliseconds intact")
    func decodesRealRow() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "mailbox", body: deliveredRow)
        let letters = try await makeStore(transport).mailbox()

        let letter = try #require(letters.first)
        #expect(letter.id == "l-1")
        #expect(letter.state == .delivered)
        #expect(!letter.isOutbound, "it came from them")
        #expect(letter.correspondentID == "them-uuid")

        // The exact instant the backend verified round-trips through Postgres.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(iso.string(from: try #require(letter.expectedDeliveryDate))
            == "2026-07-23T21:06:00.000Z")
        #expect(letter.postmarkDate != nil, "a bare date must decode too")
        #expect(letter.readAt == nil)

        // The populated optional timestamps, by value. Asserting only that the
        // nulls are nil let a misspelled key for any of these survive: absent
        // and wrongly-named both decode to nil, and nil equals nil.
        #expect(iso.string(from: try #require(letter.collectedAt))
            == "2026-08-15T21:00:00.000Z")
        #expect(iso.string(from: try #require(letter.deliveredAt))
            == "2026-08-20T16:23:00.000Z")
        #expect(iso.string(from: try #require(letter.writtenAt))
            == "2026-08-15T15:00:00.000Z")
    }

    @Test("An opened letter carries the moment it was opened")
    func readAtDecodes() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "mailbox", body: readRow)
        let letter = try #require(try await makeStore(transport).mailbox().first)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(iso.string(from: try #require(letter.readAt)) == "2026-08-14T18:05:00.000Z")
        #expect(letter.readAt != letter.deliveredAt, "opened later than it landed")
    }

    @Test("A letter I wrote reads as outbound")
    func outboundOrientation() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "outbox", body: deliveredRow)
        let letters = try await makeStore(transport, me: "them-uuid").outbox()
        let letter = try #require(letters.first)
        #expect(letter.isOutbound)
        #expect(letter.correspondentID == "me-uuid", "the other party is the recipient")
    }

    @Test("Postgres state names map to postal states")
    func stateNames() {
        #expect(LetterState(databaseValue: "awaiting_collection") == .awaitingCollection)
        #expect(LetterState(databaseValue: "in_transit") == .inTransit)
        #expect(LetterState(databaseValue: "delivered") == .delivered)
        #expect(LetterState(databaseValue: "revoked") == .revoked)
        // Decoding by rawValue would accept none of these.
        #expect(LetterState(databaseValue: "inTransit") == nil)
        #expect(LetterState(databaseValue: "posted") == nil)
    }

    @Test("An unreadable body is an error, not an empty mailbox")
    func malformedIsNotEmpty() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "mailbox", body: "{ not json")
        await #expect(throws: MailStoreError.malformedResponse) {
            _ = try await makeStore(transport).mailbox()
        }
    }
}

@Suite("Refusals keep their meaning")
struct SupabaseErrorTests {

    @Test("Each database code becomes the error it means")
    func codesMap() {
        func failure(_ code: String) -> Data {
            Data(#"{"code":"\#(code)","message":"nope"}"#.utf8)
        }
        #expect(SupabaseMailStore.error(from: failure("SM001"), status: 400) == .alreadyCollected)
        #expect(SupabaseMailStore.error(from: failure("SM004"), status: 400) == .alreadyCollected)
        #expect(SupabaseMailStore.error(from: failure("SM005"), status: 400) == .notFound)
        #expect(SupabaseMailStore.error(from: failure("SM006"), status: 400) == .emptyBody)
        #expect(SupabaseMailStore.error(from: failure("SM007"), status: 400) == .notACorrespondent)
        #expect(SupabaseMailStore.error(from: failure("SM008"), status: 400) == .noRoutableAddress)
    }

    @Test("An unknown code stays unknown rather than becoming a plausible neighbour")
    func unknownCodeIsNotGuessed() {
        let refusal = Data(#"{"code":"SM999","message":"something new"}"#.utf8)
        #expect(SupabaseMailStore.error(from: refusal, status: 400) == .serverRefused("something new"))
    }

    @Test("A rejected token is not a missing letter")
    func authIsItsOwnFailure() {
        #expect(SupabaseMailStore.error(from: Data(), status: 401) == .notPermitted)
        #expect(SupabaseMailStore.error(from: Data(), status: 403) == .notPermitted)
    }

    @Test("Revoking a collected letter surfaces as alreadyCollected")
    func revokeAfterCollection() async throws {
        let transport = RecordingTransport()
        await transport.reply(
            to: "revoke_letter", status: 400,
            body: #"{"code":"SM001","message":"the letter is collected and therefore frozen"}"#)
        await #expect(throws: MailStoreError.alreadyCollected) {
            try await makeStore(transport).revoke("l-1")
        }
    }

    @Test("An empty letter never reaches the network")
    func emptyBodyIsRefusedLocally() async throws {
        let transport = RecordingTransport()
        let store = makeStore(transport)
        await #expect(throws: MailStoreError.emptyBody) {
            _ = try await store.write(Draft(correspondentID: "them-uuid", body: "   \n "))
        }
        #expect(await transport.requests.isEmpty)
    }
}

@Suite("The carrier's round is worked out here, not asked for")
struct SupabaseCarrierTests {

    /// Asking the server when the carrier is due would make the answer depend
    /// on whether anything is coming, and a recipient could read that
    /// difference off an empty mailbox to learn a letter exists before it was
    /// delivered. The round is a function of who you are and what day it is.
    ///
    /// It does make one request — for the reader's own profile zone — so the
    /// property is not "makes no request" but "makes the same request either
    /// way". That is what an oracle would have to break.
    @Test("It asks the same thing whether or not mail is coming")
    func makesNoRequestThatDependsOnMail() async throws {
        func requests(mailbox: String) async throws -> [String] {
            let transport = RecordingTransport()
            await transport.reply(to: "mailbox", body: mailbox)
            await transport.reply(
                to: "profiles", body: #"[{"id":"me-uuid","timezone":"America/New_York"}]"#)
            let store = makeStore(
                transport, now: Fixtures.referenceDate.addingTimeInterval(-86_400 * 3))
            _ = try await store.carrierExpected(on: Fixtures.referenceDate)
            return await transport.requests.compactMap { $0.url?.absoluteString }
        }

        let withMail = try await requests(mailbox: deliveredRow)
        let withNone = try await requests(mailbox: "[]")
        #expect(withMail == withNone)
        // Not two empty lists agreeing: it really does make a request.
        #expect(withMail.count == 1)
        let only = try #require(withMail.first)
        #expect(only.contains("/rest/v1/profiles"))
        #expect(!only.contains("letters") && !only.contains("mailbox"))
    }

    @Test("A round that has already passed is not still expected")
    func pastRoundIsNotExpected() async throws {
        let transport = RecordingTransport()
        await transport.reply(
            to: "profiles", body: #"[{"id":"me-uuid","timezone":"America/New_York"}]"#)

        var newYork = Calendar(identifier: .gregorian)
        newYork.locale = Locale(identifier: "en_US_POSIX")
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let round = try #require(PostalCalendar.carrierArrival(
            forRecipient: "me-uuid", on: Fixtures.referenceDate, calendar: newYork))

        let before = makeStore(transport, now: round.addingTimeInterval(-60))
        #expect(try await before.carrierExpected(on: Fixtures.referenceDate) == round)

        let after = makeStore(transport, now: round.addingTimeInterval(60))
        #expect(try await after.carrierExpected(on: Fixtures.referenceDate) == nil)
    }
}


private let acceptedLink = """
[{"requester_id":"me-uuid","addressee_id":"them-uuid","status":"accepted"}]
"""

/// Two profiles as the columns are actually spelled: `timezone`, not `tz`.
private let bothProfiles = """
[{"id":"me-uuid","display_name":"Me","home_city_label":"Brooklyn, NY",
  "timezone":"America/New_York","home_lat":40.68,"home_lng":-73.94,
  "country_code":"US","region":"NY","is_territory":false},
 {"id":"them-uuid","display_name":"Ada","home_city_label":"San Francisco, CA",
  "timezone":"America/Los_Angeles","home_lat":37.77,"home_lng":-122.42,
  "country_code":"US","region":"CA","is_territory":false}]
"""

private let addresslessProfiles = """
[{"id":"me-uuid","display_name":"Me","home_city_label":"Brooklyn, NY",
  "timezone":"America/New_York","home_lat":40.68,"home_lng":-73.94,
  "country_code":"US","region":"NY","is_territory":false},
 {"id":"them-uuid","display_name":"Nomad","home_city_label":null,
  "timezone":"UTC","home_lat":null,"home_lng":null,
  "country_code":"US","region":null,"is_territory":false}]
"""

/// San Juan is US soil, roughly 1,600 miles from Brooklyn, and therefore lands
/// in the 1,001–1,800 band on distance alone. `region` is the only thing that
/// says otherwise. If that key stops decoding, the band silently becomes 4 and
/// nothing else about the answer looks wrong.
private let puertoRicoProfiles = """
[{"id":"me-uuid","display_name":"Me","home_city_label":"Brooklyn, NY",
  "timezone":"America/New_York","home_lat":40.68,"home_lng":-73.94,
  "country_code":"US","region":"NY","is_territory":false},
 {"id":"them-uuid","display_name":"Rosa","home_city_label":"San Juan, PR",
  "timezone":"America/Puerto_Rico","home_lat":18.47,"home_lng":-66.11,
  "country_code":"US","region":"PR","is_territory":false}]
"""

/// Guam carries no region here, so `is_territory` is the only field standing
/// between a 7-day territory band and the 5-day band its distance would give.
private let guamProfiles = """
[{"id":"me-uuid","display_name":"Me","home_city_label":"Brooklyn, NY",
  "timezone":"America/New_York","home_lat":40.68,"home_lng":-73.94,
  "country_code":"US","region":"NY","is_territory":false},
 {"id":"them-uuid","display_name":"Hana","home_city_label":"Hagatna, GU",
  "timezone":"Pacific/Guam","home_lat":13.44,"home_lng":144.79,
  "country_code":"US","region":null,"is_territory":true}]
"""

@Suite("Correspondents are read from the tables that hold no secret")
struct SupabaseCorrespondentTests {

    private func store(profiles: String) async -> (SupabaseMailStore, RecordingTransport) {
        let transport = RecordingTransport()
        await transport.reply(to: "correspondents", body: acceptedLink)
        await transport.reply(to: "profiles", body: profiles)
        return (makeStore(transport), transport)
    }

    @Test("Only accepted links are asked for, and letters is still untouched")
    func asksForAcceptedOnly() async throws {
        let (store, transport) = await self.store(profiles: bothProfiles)
        _ = try await store.correspondents()

        let urls = await transport.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.count == 2)
        // A pending request is not yet a correspondent; writing to one is SM007.
        #expect(try #require(urls.first).contains("status=eq.accepted"))
        for url in urls { #expect(!url.contains("/letters")) }
        #expect(await transport.paths == ["/rest/v1/correspondents", "/rest/v1/profiles"])
    }

    /// Routing inputs are optional fields, so a wrong key decodes to nil rather
    /// than throwing. These three assert the band the field changes, not the
    /// field, because a quietly-nil `region` is only visible as a wrong number
    /// of days.
    @Test("Puerto Rico routes as non-contiguous, not as its distance")
    func regionSurvivesTheWire() async throws {
        let (store, _) = await self.store(profiles: puertoRicoProfiles)
        let rosa = try #require(try await store.correspondents().first)
        // 5 because the region says so; 4 would be the answer from miles alone.
        #expect(rosa.transit == .domestic(5))
    }

    @Test("A territory routes as a territory, not as its distance")
    func territoryFlagSurvivesTheWire() async throws {
        let (store, _) = await self.store(profiles: guamProfiles)
        let hana = try #require(try await store.correspondents().first)
        // 7 because it is a territory; 5 is what the mileage band would give.
        #expect(hana.transit == .domestic(7))
    }

    @Test("A correspondent's city is the one the server sent")
    func cityLabelSurvivesTheWire() async throws {
        let (store, _) = await self.store(profiles: puertoRicoProfiles)
        let rosa = try #require(try await store.correspondents().first)
        #expect(rosa.cityLabel == "San Juan, PR")
    }

    @Test("Distance and band come from the engine, computed against my own home")
    func routesFromBothEnds() async throws {
        let (store, _) = await self.store(profiles: bothProfiles)
        let people = try await store.correspondents()

        let ada = try #require(people.first)
        #expect(people.count == 1, "I am not my own correspondent")
        #expect(ada.id == "them-uuid")
        #expect(ada.name == "Ada")

        // Brooklyn to San Francisco is ~2570 miles, which is the 1801+ band.
        let miles = try #require(ada.milesAway)
        #expect(miles > 2500 && miles < 2650, "got \(miles)")
        #expect(ada.transit == .domestic(5))
        #expect(ada.timeZoneIdentifier == "America/Los_Angeles",
                "the `timezone` column has to reach `tz`")
    }

    @Test("Someone with no address is quoted nothing at all")
    func addresslessQuotesNothing() async throws {
        let (store, _) = await self.store(profiles: addresslessProfiles)
        let nomad = try #require(try await store.correspondents().first)

        #expect(!nomad.isReachable)
        #expect(nomad.transit == nil)
        #expect(nomad.milesAway == nil)
        // The failure this replaced was `.domestic(0)` and `0` miles, which the
        // list rendered as a confident "0 miles away · usually 0 days".
        #expect(nomad.typicalTransitDays == nil)
    }

    @Test("An unknown address is worded as one, not as a zero or a blank")
    func unknownAddressIsWorded() {
        let unknown = PostalWording.routing(miles: nil, days: nil)
        #expect(unknown == PostalWording.unaddressed)
        #expect(!unknown.contains("0"))
        #expect(unknown != "")
        #expect(PostalWording.routing(miles: 2570, days: 5).contains("2,570"))
    }

    @Test("With no accepted links, nobody's profile is fetched")
    func noLinksNoFetch() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "correspondents", body: "[]")
        #expect(try await makeStore(transport).correspondents().isEmpty)
        #expect(await transport.paths == ["/rest/v1/correspondents"])
    }
}

@Suite("The mock refuses what the server refuses")
struct MockRefusesUnroutableTests {

    @Test("Writing to someone with no address fails here as it would there")
    func mockRefusesUnroutable() async throws {
        let nowhere = Correspondent(
            id: "nowhere", name: "Nomad", cityLabel: "",
            timeZoneIdentifier: "UTC", milesAway: nil, transit: nil)
        let store = MockMailStore(
            clock: FixedClock(now: Fixtures.referenceDate),
            fixtures: Fixtures(correspondents: [nowhere], letters: []))

        await #expect(throws: MailStoreError.noRoutableAddress) {
            _ = try await store.write(Draft(correspondentID: "nowhere", body: "Hello"))
        }
        // And nothing was filed away as though it had been posted.
        #expect(try await store.outbox().isEmpty)
    }
}

@Suite("Choosing where the post comes from")
struct MailStoreConfigurationTests {

    @Test("Nothing configured is the demo")
    func nothingIsDemo() throws {
        #expect(try MailStoreConfiguration.resolve(environment: [:], bundle: [:]) == .demo)
    }

    @Test("A URL and a key reach the server")
    func bothReachTheServer() throws {
        let resolved = try MailStoreConfiguration.resolve(environment: [
            "SLOWMAIL_SUPABASE_URL": "https://abc.supabase.co",
            "SLOWMAIL_SUPABASE_ANON_KEY": "anon",
        ], bundle: [:])
        #expect(resolved == .supabase(url: URL(string: "https://abc.supabase.co")!, apiKey: "anon"))
    }

    /// The failure this guards against is the quiet one: a build that meant to
    /// talk to a server, was misconfigured, and served fixtures instead — which
    /// would show a reader mail that had not been delivered.
    @Test("Half a configuration is an error, never the demo")
    func halfIsAnError() {
        #expect(throws: MailStoreConfigurationError.incomplete(missing: "SLOWMAIL_SUPABASE_ANON_KEY")) {
            try MailStoreConfiguration.resolve(
                environment: ["SLOWMAIL_SUPABASE_URL": "https://abc.supabase.co"], bundle: [:])
        }
        #expect(throws: MailStoreConfigurationError.incomplete(missing: "SLOWMAIL_SUPABASE_URL")) {
            try MailStoreConfiguration.resolve(
                environment: ["SLOWMAIL_SUPABASE_ANON_KEY": "anon"], bundle: [:])
        }
    }

    @Test("Whitespace is not a configuration either")
    func whitespaceIsDemo() throws {
        let resolved = try MailStoreConfiguration.resolve(
            environment: ["SLOWMAIL_SUPABASE_URL": "  ", "SLOWMAIL_SUPABASE_ANON_KEY": " "],
            bundle: [:])
        #expect(resolved == .demo)
    }

    @Test("Plain http is refused; the token and the letters are on that wire")
    func httpIsRefused() {
        #expect(throws: MailStoreConfigurationError.badURL("http://abc.supabase.co")) {
            try MailStoreConfiguration.resolve(environment: [
                "SLOWMAIL_SUPABASE_URL": "http://abc.supabase.co",
                "SLOWMAIL_SUPABASE_ANON_KEY": "anon",
            ], bundle: [:])
        }
    }

    @Test("A configured server with nobody signed in refuses rather than serving fixtures")
    func configuredButSignedOut() throws {
        let configured = MailStoreConfiguration.supabase(
            url: URL(string: "https://abc.supabase.co")!, apiKey: "anon")
        #expect(throws: MailStoreConfigurationError.notSignedIn) {
            _ = try configured.store(clock: FixedClock(now: Fixtures.referenceDate))
        }
        // And the demo needs nobody signed in, because it is nobody's mail.
        #expect(throws: Never.self) {
            _ = try MailStoreConfiguration.demo.store(
                clock: FixedClock(now: Fixtures.referenceDate))
        }
    }
}

@Suite("Dates arrive in the shapes Postgres actually sends")
struct PostalDateFormatTests {

    /// PostgREST renders timestamptz with a numeric offset, not `Z`, and
    /// Postgres keeps microseconds. Every shape below has been seen on the wire.
    @Test("Every timestamp shape resolves to the same instant")
    func everyTimestampShape() throws {
        let expected = try #require(PostalDateFormats.parse("2026-07-23T21:06:00.000Z"))
        for text in [
            "2026-07-23T21:06:00+00:00",
            "2026-07-23T21:06:00Z",
            "2026-07-23T17:06:00-04:00",
            "2026-07-24T06:06:00+09:00",
        ] {
            let parsed = try #require(PostalDateFormats.parse(text), "did not parse: \(text)")
            #expect(parsed == expected, "\(text) gave \(parsed)")
        }
    }

    @Test("Microseconds keep their value rather than being read as something else")
    func microseconds() throws {
        let micro = try #require(PostalDateFormats.parse("2026-07-23T21:06:00.123456+00:00"))
        let milli = try #require(PostalDateFormats.parse("2026-07-23T21:06:00.123Z"))
        #expect(micro == milli)
        #expect(micro != PostalDateFormats.parse("2026-07-23T21:06:00Z"))
    }

    /// The bug this replaced: a `date` has no zone, so reading it as UTC
    /// midnight and rendering it in the reader's calendar moved every postmark
    /// back a day for everyone west of UTC.
    @Test("A postmark is the day it says, in every zone that reads it")
    func postmarkKeepsItsDay() throws {
        for zone in ["America/Los_Angeles", "America/New_York", "UTC",
                     "Europe/London", "Asia/Tokyo", "Pacific/Kiritimati"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = try #require(TimeZone(identifier: zone))

            let parsed = try #require(
                PostalDateFormats.parse("2026-08-15", calendar: calendar), "\(zone)")
            let parts = calendar.dateComponents([.year, .month, .day], from: parsed)
            #expect(parts.year == 2026 && parts.month == 8 && parts.day == 15,
                    "in \(zone) the 15th read back as \(parts)")

            let shown = DateFormatter()
            shown.calendar = calendar
            shown.timeZone = calendar.timeZone
            shown.locale = Locale(identifier: "en_US_POSIX")
            shown.dateFormat = "EEEE d MMMM"
            #expect(shown.string(from: parsed) == "Saturday 15 August", "\(zone)")
        }
    }

    /// Why the day is rebuilt at midday rather than at midnight.
    ///
    /// Midnight leaves no slack in one direction: a postmark parsed in one zone
    /// and read by a calendar behind it slips to the previous day immediately.
    /// Midday is eleven hours of slack either way.
    ///
    /// It is not more than that, and the first version of this test claimed it
    /// was. No instant renders as the same calendar date everywhere — the zones
    /// run from UTC-12 to UTC+14, which is twenty-six hours — so a reader far
    /// enough ahead still sees the next day. The guarantee is that the calendar
    /// which parses a postmark is the calendar that renders it, which is what
    /// the default argument arranges and what the test above pins. This one
    /// only shows the tolerance around it.
    @Test("A postmark tolerates a reader up to eleven hours out either way")
    func postmarkToleratesReaderSkew() throws {
        let parsedInUTC = try #require(
            PostalDateFormats.parse("2026-08-15", calendar: .gregorianUTC))

        for offset in stride(from: -11, through: 11, by: 1) {
            var reader = Calendar(identifier: .gregorian)
            reader.locale = Locale(identifier: "en_US_POSIX")
            reader.timeZone = try #require(TimeZone(secondsFromGMT: offset * 3600))
            let day = reader.component(.day, from: parsedInUTC)
            #expect(day == 15, "read at UTC\(offset) the 15th became the \(day)")
        }
    }

    /// Every other test here passes a calendar explicitly, so the argument the
    /// production decoder actually uses — the default — was unasserted. Putting
    /// `.gregorianUTC` back left all 106 green while restoring the day shift.
    ///
    /// Local midday and UTC midday are different instants in any zone but UTC,
    /// so this compares instants rather than rendered days: in New York the day
    /// renders the same either way and only the instant tells them apart.
    @Test("The default calendar is the one that will render the date")
    func defaultCalendarIsTheRenderingOne() throws {
        #expect(
            TimeZone.current.secondsFromGMT() != 0,
            "the suite pins a non-UTC zone; in UTC this test cannot fail")

        let production = try #require(PostalDateFormats.parse("2026-08-15"))
        let localMidday = try #require(
            Calendar.postal.date(
                from: DateComponents(year: 2026, month: 8, day: 15, hour: 12)))
        let utcMidday = try #require(
            Calendar.gregorianUTC.date(
                from: DateComponents(year: 2026, month: 8, day: 15, hour: 12)))

        #expect(production == localMidday)
        #expect(production != utcMidday, "the default fell back to UTC")
    }

    /// The same property through the real decoder, since that is what a letter
    /// is actually built by.
    @Test("A decoded letter's postmark is the day the server sent")
    func decodedPostmarkKeepsItsDay() throws {
        let json = Data(#"{"postmark_date":"2026-08-15"}"#.utf8)
        struct OnlyPostmark: Decodable {
            let postmarkDate: Date
            enum CodingKeys: String, CodingKey { case postmarkDate = "postmark_date" }
        }
        let decoded = try JSONDecoder.postal.decode(OnlyPostmark.self, from: json)
        let parts = Calendar.postal.dateComponents(
            [.year, .month, .day], from: decoded.postmarkDate)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 15)
    }

    @Test("Something that is not a date is nil, not today")
    func rubbishIsNil() {
        #expect(PostalDateFormats.parse("") == nil)
        #expect(PostalDateFormats.parse("not a date") == nil)
        #expect(PostalDateFormats.parse("2026-13-45") == nil)
    }
}

/// `write_letter` is declared `returns public.letters`, so PostgREST sends one
/// object. Every earlier test used an array and could not have seen this.
private let writtenRow = """
{"id":"l-9","sender_id":"me-uuid","recipient_id":"them-uuid","body":"Hello",
 "state":"awaiting_collection","written_at":"2026-08-20T19:40:00+00:00",
 "collected_at":null,"postmark_date":"2026-08-20","deliver_at":null,
 "delivered_at":null,"read_at":null}
"""

@Suite("Posting a letter reports what actually happened")
struct SupabaseWriteTests {

    @Test("A successful send is read as a success, not a malformed reply")
    func scalarReplyDecodes() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "write_letter", body: writtenRow)
        let letter = try await makeStore(transport)
            .write(Draft(correspondentID: "them-uuid", body: "Hello"))

        // Decoding this as an array threw .malformedResponse while the letter
        // was already inserted and posted — so the sender was told it failed
        // and a second tap posted a second real letter that cannot be recalled
        // once collected.
        #expect(letter.id == "l-9")
        #expect(letter.isOutbound)
        #expect(letter.state == .awaitingCollection)
        #expect(letter.correspondentID == "them-uuid")
        #expect(letter.postmarkDate != nil)
        #expect(letter.expectedDeliveryDate == nil, "nothing is scheduled until collection")
    }

    @Test("The recipient and body are sent under the names the function expects")
    func argumentNamesAreRight() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "write_letter", body: writtenRow)
        _ = try await makeStore(transport)
            .write(Draft(correspondentID: "them-uuid", body: "  Hello  "))

        let sent = try #require(await transport.requests.first?.httpBody)
        let arguments = try #require(
            try JSONSerialization.jsonObject(with: sent) as? [String: String])
        // A wrong name is not a type error anywhere in Swift; PostgREST answers
        // 404 "function not found", which reads like an outage.
        #expect(arguments == ["p_recipient_id": "them-uuid", "p_body": "Hello"])
    }

    @Test("Each single-argument RPC names its argument correctly")
    func singleArgumentNames() async throws {
        func argument(_ call: (SupabaseMailStore) async throws -> Void) async throws -> [String: String] {
            let transport = RecordingTransport()
            try? await call(makeStore(transport))
            let body = try #require(await transport.requests.first?.httpBody)
            return try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        }
        #expect(try await argument { try await $0.revoke("l-1") } == ["p_letter_id": "l-1"])
        #expect(try await argument { try await $0.markRead("l-1") } == ["p_letter_id": "l-1"])
        #expect(try await argument { _ = try await $0.correspondence(with: "c-1") }
            == ["p_correspondent_id": "c-1"])
    }

    @Test("Null timestamps stay absent rather than becoming an instant")
    func nullsDecodeAsNil() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "write_letter", body: writtenRow)
        let letter = try await makeStore(transport)
            .write(Draft(correspondentID: "them-uuid", body: "Hello"))
        #expect(letter.collectedAt == nil)
        #expect(letter.deliveredAt == nil)
        #expect(letter.readAt == nil)
        // And a present one is present, so this is not two absences agreeing.
        #expect(letter.writtenAt != Date(timeIntervalSince1970: 0))
    }
}

@Suite("Table reads are held to the same rules as function calls")
struct SupabaseTableReadTests {

    @Test("Neither table read asks for a count either")
    func tableReadsAskNoCount() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "correspondents", body: acceptedLink)
        await transport.reply(to: "profiles", body: bothProfiles)
        _ = try await makeStore(transport).correspondents()

        #expect(await transport.requests.count == 2, "both reads must be exercised")
        for request in await transport.requests {
            // HTTP header names are case-insensitive and URLRequest keeps the
            // casing it was given, so a dictionary lookup for one spelling misses
            // the other.
            let prefer = request.value(forHTTPHeaderField: "Prefer") ?? ""
            #expect(!prefer.contains("count"), "asked for a count: \(prefer)")
            #expect(request.allHTTPHeaderFields?["Authorization"] == "Bearer jwt-abc")
        }
    }

    @Test("The profiles query names both parties, not just the other one")
    func profileQueryNamesBoth() async throws {
        let transport = RecordingTransport()
        await transport.reply(to: "correspondents", body: acceptedLink)
        await transport.reply(to: "profiles", body: bothProfiles)
        _ = try await makeStore(transport).correspondents()

        let url = try #require(await transport.requests.last?.url?.absoluteString)
        // Dropping my own id from the filter leaves the real server unable to
        // return my coordinates, and every distance would be computed against
        // nothing. The stub returns both regardless, so this reads the request.
        #expect(url.contains("me-uuid"))
        #expect(url.contains("them-uuid"))
    }
}

@Suite("The round is drawn in the recipient's zone, not this device's")
struct SupabaseCarrierZoneTests {

    private func transport(zone: String) async -> RecordingTransport {
        let transport = RecordingTransport()
        await transport.reply(
            to: "profiles", body: #"[{"id":"me-uuid","timezone":"\#(zone)"}]"#)
        return transport
    }

    @Test("It uses the profile's zone")
    func usesProfileZone() async throws {
        let transport = await transport(zone: "Asia/Tokyo")
        let expected = try await makeStore(transport, now: Fixtures.referenceDate.addingTimeInterval(-86_400 * 3))
            .carrierExpected(on: Fixtures.referenceDate)

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.locale = Locale(identifier: "en_US_POSIX")
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(expected == PostalCalendar.carrierArrival(
            forRecipient: "me-uuid", on: Fixtures.referenceDate, calendar: tokyo))
    }

    /// The bug: the device's zone travels with its owner and the server's does
    /// not, so a reader who flew somewhere got an estimate a whole round out.
    @Test("Two zones give two different instants, so the choice is load-bearing")
    func theZoneChoiceMatters() async throws {
        func round(_ zone: String) async throws -> Date? {
            try await makeStore(
                await transport(zone: zone),
                now: Fixtures.referenceDate.addingTimeInterval(-86_400 * 3)
            ).carrierExpected(on: Fixtures.referenceDate)
        }
        let tokyo = try #require(try await round("Asia/Tokyo"))
        let newYork = try #require(try await round("America/New_York"))
        #expect(tokyo != newYork)
    }

    @Test("The profile is asked for once, however often the round is wanted")
    func zoneIsFetchedOnce() async throws {
        let transport = await transport(zone: "Asia/Tokyo")
        let store = makeStore(transport, now: Fixtures.referenceDate.addingTimeInterval(-86_400 * 3))
        for _ in 0..<4 { _ = try await store.carrierExpected(on: Fixtures.referenceDate) }
        #expect(await transport.requests.count == 1)
    }
}

@Suite("A misconfigured build says so instead of inventing letters")
struct AppStartTests {

    @Test("A configured server with no session refuses rather than showing fixtures")
    func configuredWithoutSession() {
        let reason = MailStoreConfiguration.explain(MailStoreConfigurationError.notSignedIn)
        #expect(reason.contains("nobody is signed in"))
        #expect(!reason.isEmpty)
    }

    @Test("The reason names the key that is wrong")
    func reasonNamesTheKey() {
        let reason = MailStoreConfiguration.explain(
            MailStoreConfigurationError.incomplete(missing: "SLOWMAIL_SUPABASE_URL"))
        #expect(reason.contains("SLOWMAIL_SUPABASE_URL"))
    }

    @Test("Info.plist is actually read, not defaulted away")
    func bundleIsRead() throws {
        let resolved = try MailStoreConfiguration.resolve(
            environment: [:],
            bundle: [
                "SlowmailSupabaseURL": "https://plist.supabase.co",
                "SlowmailSupabaseAnonKey": "plist-key",
            ])
        // The bug: `bundle` defaulted to [:], so the documented shipping
        // configuration was never consulted and every build ran on fixtures.
        #expect(resolved == .supabase(
            url: URL(string: "https://plist.supabase.co")!, apiKey: "plist-key"))
    }

    @Test("The environment wins over the bundle, so a debug run can redirect")
    func environmentWins() throws {
        let resolved = try MailStoreConfiguration.resolve(
            environment: [
                "SLOWMAIL_SUPABASE_URL": "https://env.supabase.co",
                "SLOWMAIL_SUPABASE_ANON_KEY": "env-key",
            ],
            bundle: [
                "SlowmailSupabaseURL": "https://plist.supabase.co",
                "SlowmailSupabaseAnonKey": "plist-key",
            ])
        #expect(resolved == .supabase(
            url: URL(string: "https://env.supabase.co")!, apiKey: "env-key"))
    }
}

@Suite("Info.plist keys are read from the bundle")
struct BundleConfigurationTests {

    @Test("Both documented keys are picked up")
    func readsBothKeys() {
        let source = [
            "SlowmailSupabaseURL": "https://plist.supabase.co",
            "SlowmailSupabaseAnonKey": "plist-key",
        ]
        #expect(Bundle.slowmailConfiguration { source[$0] } == source)
    }

    @Test("A key that is not a string is not a configuration")
    func nonStringIsIgnored() {
        #expect(Bundle.slowmailConfiguration { _ in 42 }.isEmpty)
        #expect(Bundle.slowmailConfiguration { _ in nil }.isEmpty)
    }

    @Test("Nothing else in Info.plist is picked up by accident")
    func onlyTheTwoKeys() {
        let found = Bundle.slowmailConfiguration { _ in "value" }
        #expect(Set(found.keys) == ["SlowmailSupabaseURL", "SlowmailSupabaseAnonKey"])
    }
}
