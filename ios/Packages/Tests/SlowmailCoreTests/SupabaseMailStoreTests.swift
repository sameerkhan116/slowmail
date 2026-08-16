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
            let prefer = header["Prefer"] ?? ""
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
    /// on whether anything is coming, and a recipient could read that off an
    /// empty mailbox to learn a letter exists before it was delivered.
    @Test("carrierExpected makes no request")
    func roundIsLocal() async throws {
        let transport = RecordingTransport()
        let store = makeStore(transport)
        _ = try await store.carrierExpected(on: Fixtures.referenceDate)
        #expect(await transport.requests.isEmpty)
    }

    @Test("It agrees with the round the rest of the app uses")
    func matchesTheEngine() async throws {
        let beforeRound = try #require(
            PostalCalendar.carrierArrival(forRecipient: "me-uuid", on: Fixtures.referenceDate)
        ).addingTimeInterval(-60)
        let store = makeStore(RecordingTransport(), now: beforeRound)
        let expected = try await store.carrierExpected(on: beforeRound)
        #expect(expected == PostalCalendar.carrierArrival(
            forRecipient: "me-uuid", on: beforeRound))
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
        #expect(try MailStoreConfiguration.resolve(environment: [:]) == .demo)
    }

    @Test("A URL and a key reach the server")
    func bothReachTheServer() throws {
        let resolved = try MailStoreConfiguration.resolve(environment: [
            "SLOWMAIL_SUPABASE_URL": "https://abc.supabase.co",
            "SLOWMAIL_SUPABASE_ANON_KEY": "anon",
        ])
        #expect(resolved == .supabase(url: URL(string: "https://abc.supabase.co")!, apiKey: "anon"))
    }

    /// The failure this guards against is the quiet one: a build that meant to
    /// talk to a server, was misconfigured, and served fixtures instead — which
    /// would show a reader mail that had not been delivered.
    @Test("Half a configuration is an error, never the demo")
    func halfIsAnError() {
        #expect(throws: MailStoreConfigurationError.incomplete(missing: "SLOWMAIL_SUPABASE_ANON_KEY")) {
            try MailStoreConfiguration.resolve(
                environment: ["SLOWMAIL_SUPABASE_URL": "https://abc.supabase.co"])
        }
        #expect(throws: MailStoreConfigurationError.incomplete(missing: "SLOWMAIL_SUPABASE_URL")) {
            try MailStoreConfiguration.resolve(
                environment: ["SLOWMAIL_SUPABASE_ANON_KEY": "anon"])
        }
    }

    @Test("Whitespace is not a configuration either")
    func whitespaceIsDemo() throws {
        let resolved = try MailStoreConfiguration.resolve(
            environment: ["SLOWMAIL_SUPABASE_URL": "  ", "SLOWMAIL_SUPABASE_ANON_KEY": " "])
        #expect(resolved == .demo)
    }

    @Test("Plain http is refused; the token and the letters are on that wire")
    func httpIsRefused() {
        #expect(throws: MailStoreConfigurationError.badURL("http://abc.supabase.co")) {
            try MailStoreConfiguration.resolve(environment: [
                "SLOWMAIL_SUPABASE_URL": "http://abc.supabase.co",
                "SLOWMAIL_SUPABASE_ANON_KEY": "anon",
            ])
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

    @Test("Something that is not a date is nil, not today")
    func rubbishIsNil() {
        #expect(PostalDateFormats.parse("") == nil)
        #expect(PostalDateFormats.parse("not a date") == nil)
        #expect(PostalDateFormats.parse("2026-13-45") == nil)
    }
}
