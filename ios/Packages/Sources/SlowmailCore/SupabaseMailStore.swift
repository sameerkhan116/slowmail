import Foundation
import MailClockKit

/// The one thing the app does over the network, isolated so it can be tested
/// without one.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MailStoreError.unreachable
        }
        return (data, http)
    }
}

/// Supplies the caller's identity. Separated from the store so signing in,
/// refreshing, and signing out are somebody else's problem.
public protocol TokenProvider: Sendable {
    func accessToken() async throws -> String
    var userID: CorrespondentID { get async }
}

/// The post office, over the wire.
///
/// Every read goes through a database function — `mailbox`, `outbox`,
/// `correspondence` — and never through the `letters` table. That is not a
/// style preference. The table is not readable by clients at all, because
/// PostgREST will answer a request for a *count* of rows a caller cannot see,
/// and a count of undelivered letters tells a recipient that someone has
/// written to them. Removing the endpoint was the fix; asking only for the
/// functions is this side of it.
public actor SupabaseMailStore: MailStore {
    private let baseURL: URL
    private let apiKey: String
    private let tokens: any TokenProvider
    private let transport: any HTTPTransport
    private let clock: any Clock

    public init(
        baseURL: URL,
        apiKey: String,
        tokens: any TokenProvider,
        clock: any Clock,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tokens = tokens
        self.clock = clock
        self.transport = transport
    }

    // MARK: Reading

    public func mailbox() async throws -> [Letter] {
        let me = await tokens.userID
        return try await call("mailbox").map { try $0.letter(viewedBy: me) }
    }

    public func outbox() async throws -> [Letter] {
        let me = await tokens.userID
        return try await call("outbox").map { try $0.letter(viewedBy: me) }
    }

    public func correspondence(with id: CorrespondentID) async throws -> [Letter] {
        let me = await tokens.userID
        return try await call("correspondence", ["p_correspondent_id": id])
            .map { try $0.letter(viewedBy: me) }
    }

    /// The correspondent list is read from the tables rather than a function,
    /// because unlike `letters` these carry no secret. A row of `correspondents`
    /// or `profiles` is visible to the caller or it is not; there is no state in
    /// which a row exists but must stay hidden until a future instant, so a row
    /// count discloses nothing that a `select` would not.
    public func correspondents() async throws -> [Correspondent] {
        let me = await tokens.userID
        let links: [LinkRow] = try await decode(
            await get("correspondents", [
                "select": "requester_id,addressee_id,status",
                "status": "eq.accepted",
            ]))
        let others = Set(links.flatMap { [$0.requesterID, $0.addresseeID] }).subtracting([me])
        guard !others.isEmpty else { return [] }

        // Mine as well as theirs: distance is a relation, so the sender's own
        // coordinates are half of every answer.
        let wanted = others.union([me]).sorted()
        let profiles: [ProfileRow] = try await decode(
            await get("profiles", [
                "select": "id,display_name,home_city_label,timezone,home_lat,home_lng,"
                    + "country_code,region,is_territory",
                "id": "in.(\(wanted.joined(separator: ",")))",
            ]))
        let mine = profiles.first { $0.id == me }
        return profiles
            .filter { others.contains($0.id) }
            .map { $0.correspondent(seenFrom: mine) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func correspondent(_ id: CorrespondentID) async throws -> Correspondent {
        guard let match = try await correspondents().first(where: { $0.id == id }) else {
            throw MailStoreError.unknownCorrespondent(id)
        }
        return match
    }

    /// Computed here rather than fetched.
    ///
    /// The server could tell us when the carrier is due, but asking would make
    /// the answer depend on whether anything is coming — and a recipient could
    /// read that difference off an empty mailbox to learn a letter exists
    /// before it was delivered. The round is a function of who you are and what
    /// day it is, so the device can work it out and nobody has to be asked.
    ///
    /// It is an estimate. See `MailStore.carrierExpected`.
    public func carrierExpected(on day: Date) async throws -> Date? {
        let me = await tokens.userID
        guard let arrival = PostalCalendar.carrierArrival(forRecipient: me, on: day) else {
            return nil
        }
        return arrival > clock.now ? arrival : nil
    }

    // MARK: Writing

    @discardableResult
    public func write(_ draft: Draft) async throws -> Letter {
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw MailStoreError.emptyBody }
        let me = await tokens.userID
        let rows: [LetterRow] = try await call(
            "write_letter",
            ["p_recipient_id": draft.correspondentID, "p_body": body]
        )
        guard let row = rows.first else { throw MailStoreError.notFound }
        return try row.letter(viewedBy: me)
    }

    public func revoke(_ id: LetterID) async throws {
        _ = try await rpc("revoke_letter", ["p_letter_id": id])
    }

    public func markRead(_ id: LetterID) async throws {
        _ = try await rpc("mark_letter_read", ["p_letter_id": id])
    }

    // MARK: Transport

    private func call(_ name: String, _ arguments: [String: String] = [:]) async throws -> [LetterRow] {
        try await decode(await rpc(name, arguments))
    }

    private func decode<T: Decodable>(_ data: @autoclosure () async throws -> Data) async throws -> T {
        let payload = try await data()
        do {
            return try JSONDecoder.postal.decode(T.self, from: payload)
        } catch {
            throw MailStoreError.malformedResponse
        }
    }

    /// A filtered table read. Deliberately never used for `letters`.
    private func get(_ table: String, _ query: [String: String]) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1").appendingPathComponent(table),
            resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try await authorise(&request)
        return try await run(request)
    }

    private func rpc(_ name: String, _ arguments: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("rest/v1/rpc").appendingPathComponent(name))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        try await authorise(&request)
        request.httpBody = try? JSONEncoder().encode(arguments)
        return try await run(request)
    }

    private func authorise(_ request: inout URLRequest) async throws {
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        let token = try await tokens.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func run(_ request: URLRequest) async throws -> Data {
        // Nothing here ever sets `Prefer: count=...`. Asking for a count is the
        // request that leaked: PostgREST counts rows the caller cannot read, and
        // the number of letters you cannot see yet is itself the letter.
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(from: data, status: response.statusCode)
        }
        return data
    }

    /// Postgres raises with a code; the app has its own vocabulary. Anything
    /// unrecognised stays unrecognised rather than being flattened into a
    /// plausible neighbour, because a wrong-but-specific error is worse than an
    /// honest unknown one.
    static func error(from data: Data, status: Int) -> MailStoreError {
        if status == 401 || status == 403 { return .notPermitted }
        guard let failure = try? JSONDecoder().decode(PostgresFailure.self, from: data) else {
            return .unreachable
        }
        switch failure.code {
        case "SM001", "SM004": return .alreadyCollected
        case "SM005": return .notFound
        case "SM006": return .emptyBody
        case "SM007": return .notACorrespondent
        case "SM008": return .noRoutableAddress
        default: return .serverRefused(failure.message)
        }
    }

}

private struct PostgresFailure: Decodable {
    let code: String?
    let message: String
}

struct LinkRow: Decodable {
    let requesterID: String
    let addresseeID: String
    let status: String

    // Spelled out rather than left to key conversion: `requester_id` converts
    // to `requesterId`, which is not what this property is called.
    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case addresseeID = "addressee_id"
        case status
    }
}

struct ProfileRow: Decodable {
    let id: String
    let displayName: String
    let homeCityLabel: String?
    let tz: String
    let homeLat: Double?
    let homeLng: Double?
    let countryCode: String
    let region: String?
    let isTerritory: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case homeCityLabel = "home_city_label"
        // The column is `timezone`; the engine's word is `tz`. Neither name
        // survives key conversion into the other.
        case tz = "timezone"
        case homeLat = "home_lat"
        case homeLng = "home_lng"
        case countryCode = "country_code"
        case region
        case isTerritory = "is_territory"
    }

    var party: Party? {
        guard let homeLat, let homeLng else { return nil }
        return Party(
            timeZone: tz,
            latitude: homeLat,
            longitude: homeLng,
            countryCode: countryCode,
            region: region,
            isTerritory: isTerritory ?? false
        )
    }

    /// Banding is the engine's, never this file's. A second copy of the
    /// distance table here is exactly the divergence the port was done to end.
    func correspondent(seenFrom me: ProfileRow?) -> Correspondent {
        guard let mine = me?.party, let theirs = party else {
            // No routable address on one side. The server refuses to post to
            // this person, so quote nothing rather than invent a number.
            return Correspondent(
                id: id, name: displayName, cityLabel: homeCityLabel ?? "",
                timeZoneIdentifier: tz, milesAway: nil, transit: nil)
        }
        let miles = haversineMiles(
            aLatitude: mine.latitude, aLongitude: mine.longitude,
            bLatitude: theirs.latitude, bLongitude: theirs.longitude)

        if mine.countryCode != theirs.countryCode {
            let band = internationalBand(countryCode: theirs.countryCode)
            return Correspondent(
                id: id, name: displayName, cityLabel: homeCityLabel ?? "",
                timeZoneIdentifier: tz, milesAway: Int(miles.rounded()),
                // A band, shown as its midpoint: quoting the floor would make
                // most mail look late.
                transit: .international((band.min + band.max) / 2))
        }
        return Correspondent(
            id: id, name: displayName, cityLabel: homeCityLabel ?? "",
            timeZoneIdentifier: tz, milesAway: Int(miles.rounded()),
            transit: .domestic(baseDomesticTransitDays(miles, sender: mine, recipient: theirs)))
    }
}

struct LetterRow: Decodable {
    let id: String
    let senderId: String
    let recipientId: String
    let body: String
    let state: String
    let writtenAt: Date?
    let collectedAt: Date?
    let postmarkDate: Date?
    let deliverAt: Date?
    let deliveredAt: Date?
    let readAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case senderId = "sender_id"
        case recipientId = "recipient_id"
        case body
        case state
        case writtenAt = "written_at"
        case collectedAt = "collected_at"
        case postmarkDate = "postmark_date"
        case deliverAt = "deliver_at"
        case deliveredAt = "delivered_at"
        case readAt = "read_at"
    }

    func letter(viewedBy me: CorrespondentID) throws -> Letter {
        let outbound = senderId == me
        guard let state = LetterState(databaseValue: state) else {
            throw MailStoreError.malformedResponse
        }
        return Letter(
            id: id,
            correspondentID: outbound ? recipientId : senderId,
            isOutbound: outbound,
            body: body,
            state: state,
            writtenAt: writtenAt ?? Date(timeIntervalSince1970: 0),
            collectedAt: collectedAt,
            postmarkDate: postmarkDate,
            expectedDeliveryDate: deliverAt,
            deliveredAt: deliveredAt,
            readAt: readAt
        )
    }
}

extension LetterState {
    /// Postgres spells these with underscores. Decoding by `rawValue` would
    /// silently turn every letter into a decode failure, so the mapping is
    /// written out and exhaustive.
    init?(databaseValue: String) {
        switch databaseValue {
        case "draft", "awaiting_collection": self = .awaitingCollection
        case "in_transit": self = .inTransit
        case "delivered": self = .delivered
        case "revoked": self = .revoked
        default: return nil
        }
    }
}

extension JSONDecoder {
    /// Postgres renders `timestamptz` with fractional seconds, and `date`
    /// without a time at all. A decoder that handles only one of those fails on
    /// real rows.
    static let postal: JSONDecoder = {
        let decoder = JSONDecoder()
        // No key-conversion strategy. Every wire name is written out in a
        // CodingKeys below, because conversion rewrites the JSON key before it
        // looks for a match and would quietly stop finding these.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = PostalDateFormats.parse(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
            }
            return date
        }
        return decoder
    }()
}

enum PostalDateFormats {
    private nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private nonisolated(unsafe) static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ text: String) -> Date? {
        withFraction.date(from: text)
            ?? withoutFraction.date(from: text)
            ?? dateOnly.date(from: text)
    }
}
