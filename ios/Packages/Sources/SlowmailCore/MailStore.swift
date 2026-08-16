import Foundation

/// Everything the app can ask of the post.
///
/// The real implementation talks to a server that withholds letters until they
/// are delivered; the mock reproduces that by filtering on the clock. No view
/// reaches around this protocol, so swapping one for the other changes nothing
/// above it.
public protocol MailStore: Sendable {
    /// Letters that have arrived. Never includes anything still in transit.
    func mailbox() async throws -> [Letter]
    func outbox() async throws -> [Letter]
    func correspondence(with correspondentID: CorrespondentID) async throws -> [Letter]
    func correspondents() async throws -> [Correspondent]
    func correspondent(_ id: CorrespondentID) async throws -> Correspondent

    @discardableResult
    func write(_ draft: Draft) async throws -> Letter
    /// Only possible before collection; throws `.alreadyCollected` after.
    func revoke(_ id: LetterID) async throws
    func markRead(_ id: LetterID) async throws

    /// When today's post is expected to land, if anything is still coming.
    ///
    /// An estimate, and deliberately only that. Client and server draw the same
    /// round from the same seed, but they resolve the recipient's local time
    /// against their own copy of the timezone database. Those copies disagree —
    /// Swift ships 2026c, Node's ICU is older, and for a zone whose rules
    /// changed between them the same wall-clock round is up to an hour apart as
    /// an absolute instant.
    ///
    /// So a client may believe the round is over while the server is still
    /// holding a letter back. `mailbox()` is the only authority on what has
    /// landed; nothing shown to the recipient may claim that the day is
    /// finished, only that the carrier is not expected again.
    func carrierExpected(on day: Date) async throws -> Date?

    /// Today's round whether or not it has already happened.
    ///
    /// `carrierExpected` goes nil the moment the round is behind us, which is
    /// precisely when the skew window still needs watching, so the refresh
    /// deadline cannot be derived from it. Recomputing the round in the UI
    /// instead is what this exists to prevent: that copy had no access to the
    /// signed-in id or the profile's zone and silently used neither.
    func carrierRound(on day: Date) async throws -> Date?
}
