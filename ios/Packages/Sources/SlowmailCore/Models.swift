import Foundation

public typealias LetterID = String
public typealias CorrespondentID = String

/// Where a letter is on its journey. The states are deliberately postal rather
/// than conversational: nothing here is "sent", "delivered to device", or "read
/// by them", because none of those are things you can know about real mail.
public enum LetterState: String, Sendable, Codable, CaseIterable {
    /// Written but not yet handed over. Still editable, still revocable.
    case awaitingCollection
    /// Collected. Irrevocable from here on.
    case inTransit
    /// In the recipient's mailbox.
    case delivered
    /// Pulled back before the box was emptied.
    case revoked
}

public struct Correspondent: Sendable, Identifiable, Hashable, Codable {
    public let id: CorrespondentID
    public let name: String
    /// City-level only. We never ask for or store a street address.
    public let cityLabel: String
    public let timeZoneIdentifier: String
    /// Nil when the person has no address on file. See `transit`.
    public let milesAway: Int?
    /// Typical one-way transit, for setting expectations before you write.
    ///
    /// Nil when we do not know where this person lives. A profile may carry no
    /// coordinates at all, and the post office refuses to route to one — so
    /// there is no number to quote, and quoting a plausible one would be worse
    /// than quoting none.
    public let transit: Transit?

    /// For display only. The unit is what matters to the arithmetic.
    public var typicalTransitDays: Int? { transit?.days }

    /// Whether the post office can carry a letter to this person at all.
    public var isReachable: Bool { transit != nil }

    public init(
        id: CorrespondentID,
        name: String,
        cityLabel: String,
        timeZoneIdentifier: String,
        milesAway: Int?,
        transit: Transit?
    ) {
        self.id = id
        self.name = name
        self.cityLabel = cityLabel
        self.timeZoneIdentifier = timeZoneIdentifier
        self.milesAway = milesAway
        self.transit = transit
    }
}

public struct Letter: Sendable, Identifiable, Hashable, Codable {
    public let id: LetterID
    public let correspondentID: CorrespondentID
    /// True when this user wrote it, false when it arrived.
    public let isOutbound: Bool
    public let body: String
    public let state: LetterState
    public let writtenAt: Date
    /// Nil until the box is emptied. Non-nil means it can never be taken back.
    public let collectedAt: Date?
    public let postmarkDate: Date?
    public let expectedDeliveryDate: Date?
    public let deliveredAt: Date?
    public let readAt: Date?

    public init(
        id: LetterID,
        correspondentID: CorrespondentID,
        isOutbound: Bool,
        body: String,
        state: LetterState,
        writtenAt: Date,
        collectedAt: Date? = nil,
        postmarkDate: Date? = nil,
        expectedDeliveryDate: Date? = nil,
        deliveredAt: Date? = nil,
        readAt: Date? = nil
    ) {
        self.id = id
        self.correspondentID = correspondentID
        self.isOutbound = isOutbound
        self.body = body
        self.state = state
        self.writtenAt = writtenAt
        self.collectedAt = collectedAt
        self.postmarkDate = postmarkDate
        self.expectedDeliveryDate = expectedDeliveryDate
        self.deliveredAt = deliveredAt
        self.readAt = readAt
    }

    public var isUnread: Bool { !isOutbound && state == .delivered && readAt == nil }

    /// Whether the letter can still be fetched back.
    ///
    /// Takes the current instant rather than reading stored state alone: a
    /// letter written this afternoon is still marked `.awaitingCollection` until
    /// something advances it, and without the clock it would stay revocable long
    /// after five o'clock had passed and the box had been emptied.
    public func isRevocable(asOf now: Date) -> Bool {
        guard isOutbound, state == .awaitingCollection else { return false }
        guard let postmarkDate else { return true }
        return now < postmarkDate
    }
}

public struct Draft: Sendable, Hashable {
    public let correspondentID: CorrespondentID
    public let body: String

    /// Chosen before the first attempt to post and kept across retries.
    ///
    /// A post that commits on the server and then loses its reply is
    /// indistinguishable, from here, from one that never arrived. The client
    /// has to be free to try again, so the retry carries the same key and the
    /// server returns the letter it already posted instead of posting a second.
    ///
    /// No default value: one would make "forgot to keep this stable" compile,
    /// and the resulting duplicate is unrecallable once collected.
    public let clientKey: UUID

    public init(correspondentID: CorrespondentID, body: String, clientKey: UUID) {
        self.correspondentID = correspondentID
        self.body = body
        self.clientKey = clientKey
    }
}

public enum MailStoreError: Error, Sendable, Equatable {
    /// Attempted to pull back a letter the carrier already has.
    case alreadyCollected
    case unknownLetter(LetterID)
    case unknownCorrespondent(CorrespondentID)
    case emptyBody
    /// The post office refused to say more than that this isn't yours. It
    /// deliberately does not distinguish "no such letter" from "not yours",
    /// because the difference is itself information about someone else's mail.
    case notFound
    case notACorrespondent
    /// One side has no address the routing rules can work with.
    case noRoutableAddress
    case notPermitted
    case unreachable
    case malformedResponse
    case serverRefused(String)
}
