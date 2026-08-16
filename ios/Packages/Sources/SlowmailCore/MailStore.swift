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
    func carrierExpected(on day: Date) async throws -> Date?
}
