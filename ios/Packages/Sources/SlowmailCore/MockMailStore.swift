import Foundation

/// An in-memory post office.
///
/// It enforces the same rules the server does — nothing is visible before its
/// delivery instant, nothing is revocable after collection — so building
/// against it does not teach the app habits the real backend will reject.
public actor MockMailStore: MailStore {
    private var letters: [Letter]
    private var people: [Correspondent]
    private let clock: any Clock

    public init(clock: any Clock, fixtures: Fixtures = .demo) {
        self.clock = clock
        self.letters = fixtures.letters
        self.people = fixtures.correspondents
    }

    // MARK: Reading

    /// What is physically in the box: today's round, plus anything from an
    /// earlier round the reader hasn't taken out yet.
    public func mailbox() async throws -> [Letter] {
        let calendar = Calendar.postal
        return delivered()
            .filter { calendar.isDate($0.deliveredAt ?? .distantPast, inSameDayAs: clock.now) || $0.isUnread }
            .sorted { ($0.deliveredAt ?? .distantPast) > ($1.deliveredAt ?? .distantPast) }
    }

    public func outbox() async throws -> [Letter] {
        letters
            .filter { $0.isOutbound && ($0.state == .awaitingCollection || $0.state == .inTransit) }
            .sorted { $0.writtenAt < $1.writtenAt }
    }

    public func correspondence(with correspondentID: CorrespondentID) async throws -> [Letter] {
        (delivered() + letters.filter { $0.isOutbound })
            .filter { $0.correspondentID == correspondentID && $0.state != .revoked }
            .sorted { $0.sortDate < $1.sortDate }
    }

    public func correspondents() async throws -> [Correspondent] {
        people.sorted { $0.name < $1.name }
    }

    public func correspondent(_ id: CorrespondentID) async throws -> Correspondent {
        guard let match = people.first(where: { $0.id == id }) else {
            throw MailStoreError.unknownCorrespondent(id)
        }
        return match
    }

    public func carrierExpected(on day: Date) async throws -> Date? {
        letters
            .filter { !$0.isOutbound && $0.state == .delivered }
            .compactMap(\.deliveredAt)
            .filter { Calendar.postal.isDate($0, inSameDayAs: day) && $0 > clock.now }
            .min()
    }

    // MARK: Writing

    @discardableResult
    public func write(_ draft: Draft) async throws -> Letter {
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw MailStoreError.emptyBody }
        guard people.contains(where: { $0.id == draft.correspondentID }) else {
            throw MailStoreError.unknownCorrespondent(draft.correspondentID)
        }

        let person = try await correspondent(draft.correspondentID)
        let now = clock.now
        let postmark = PostalCalendar.nextCollection(after: now)
        let letter = Letter(
            id: UUID().uuidString,
            correspondentID: draft.correspondentID,
            isOutbound: true,
            body: body,
            state: .awaitingCollection,
            writtenAt: now,
            postmarkDate: postmark,
            expectedDeliveryDate: PostalCalendar.addingPostalDays(person.typicalTransitDays, to: postmark)
        )
        letters.append(letter)
        return letter
    }

    public func revoke(_ id: LetterID) async throws {
        guard let index = letters.firstIndex(where: { $0.id == id }) else {
            throw MailStoreError.unknownLetter(id)
        }
        // The one irreversible moment in the product. Once the box is emptied,
        // there is nothing to take back.
        guard letters[index].state == .awaitingCollection else {
            throw MailStoreError.alreadyCollected
        }
        letters[index] = letters[index].with(state: .revoked)
    }

    public func markRead(_ id: LetterID) async throws {
        guard let index = letters.firstIndex(where: { $0.id == id }) else {
            throw MailStoreError.unknownLetter(id)
        }
        guard letters[index].readAt == nil else { return }
        letters[index] = letters[index].with(readAt: clock.now)
    }

    // MARK: Internals

    /// Inbound mail is invisible until the carrier has actually been.
    private func delivered() -> [Letter] {
        letters.filter { letter in
            guard !letter.isOutbound else { return false }
            guard let deliveredAt = letter.deliveredAt else { return false }
            return deliveredAt <= clock.now
        }
    }
}

private extension Letter {
    var sortDate: Date { deliveredAt ?? postmarkDate ?? writtenAt }

    func with(state: LetterState? = nil, readAt: Date? = nil) -> Letter {
        Letter(
            id: id,
            correspondentID: correspondentID,
            isOutbound: isOutbound,
            body: body,
            state: state ?? self.state,
            writtenAt: writtenAt,
            collectedAt: collectedAt,
            postmarkDate: postmarkDate,
            expectedDeliveryDate: expectedDeliveryDate,
            deliveredAt: deliveredAt,
            readAt: readAt ?? self.readAt
        )
    }
}
