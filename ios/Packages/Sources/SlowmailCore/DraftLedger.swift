import Foundation

/// What the sender has typed, and what has already gone.
///
/// Posting is asynchronous, and the composer can be dismissed and reopened
/// while a letter is in flight. That produces a case with no good answer from
/// the text alone: the words in the box are exactly the words that were sent,
/// and they might be the sender rereading what they wrote, or might be someone
/// who reopened the sheet and typed the same short reply again. Clearing them
/// deletes live writing; leaving them offers to send the letter twice.
///
/// So each composer session gets a number. A post remembers the number it
/// started under. If a newer session owns the draft by the time it lands, the
/// text stays where it is and the sent body is recorded instead — enough to
/// refuse a duplicate until the sender changes a character.
public struct DraftLedger: Equatable, Sendable {
    private var bodies: [CorrespondentID: String] = [:]
    private var posted: [CorrespondentID: String] = [:]
    private var keys: [CorrespondentID: PostingKey] = [:]
    private var generation = 0

    public init() {}

    /// The number identifying the current writing session.
    public var currentGeneration: Int { generation }

    /// A new sheet is a new session. Closing one is not, so a post still in
    /// flight when the sender walks away can still tidy up after itself.
    public mutating func openComposer() {
        generation += 1
    }

    public func body(for id: CorrespondentID) -> String {
        bodies[id] ?? ""
    }

    public mutating func setBody(_ text: String, for id: CorrespondentID) {
        bodies[id] = text
    }

    /// Whether the words currently in the box have already been sent. Changing
    /// a word makes it a different letter and lifts the block; changing it back
    /// restores it, which is correct — those exact words did go.
    public func isAlreadyPosted(_ id: CorrespondentID) -> Bool {
        guard let sent = posted[id] else { return false }
        return sent == body(for: id)
    }

    public func canPost(_ id: CorrespondentID) -> Bool {
        !body(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isAlreadyPosted(id)
    }

    /// The key identifying the letter currently being written to `id`.
    ///
    /// Stable while that letter is unsent, however many times posting is
    /// retried, because a retry is the same letter. Cleared once one has
    /// actually landed, so the next letter to the same person is a new letter
    /// even if it happens to say the same words.
    public mutating func postingKey(for id: CorrespondentID) -> PostingKey {
        if let existing = keys[id] { return existing }
        let fresh = PostingKey()
        keys[id] = fresh
        return fresh
    }

    /// Records that `body` was accepted by the post office. Returns whether the
    /// composer that sent it is still the one on screen, and so whether the
    /// sheet should close.
    @discardableResult
    public mutating func completePost(
        of body: String,
        to id: CorrespondentID,
        sentUnder sentGeneration: Int
    ) -> Bool {
        // The letter landed either way, so the key that posted it is spent in
        // both branches. Retiring it only when the sheet is still open would
        // leave a sender who walked away reusing it, and the server would
        // answer their next letter with the previous one.
        keys[id] = nil
        guard sentGeneration == generation else {
            posted[id] = body
            return false
        }
        bodies[id] = nil
        posted[id] = nil
        return true
    }
}
