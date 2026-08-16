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
    private let userID: String

    public init(clock: any Clock, fixtures: Fixtures = .demo, userID: String = Fixtures.userID) {
        self.clock = clock
        self.letters = fixtures.letters
        self.people = fixtures.correspondents
        self.userID = userID
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
            .map(collected)
            .filter { $0.isOutbound && ($0.state == .awaitingCollection || $0.state == .inTransit) }
            .sorted { $0.writtenAt < $1.writtenAt }
    }

    public func correspondence(with correspondentID: CorrespondentID) async throws -> [Letter] {
        (delivered() + letters.filter { $0.isOutbound }.map(collected))
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

    /// When the carrier is next expected here, or nil once they have been.
    ///
    /// Derived from the round, never from the mail. Deriving it from pending
    /// letters would mean the answer is non-nil only when something is actually
    /// coming, and a recipient could read that difference off the empty state to
    /// learn a letter exists before it was delivered.
    public func carrierExpected(on day: Date) async throws -> Date? {
        guard let arrival = PostalCalendar.carrierArrival(forRecipient: userID, on: day) else {
            return nil
        }
        return arrival > clock.now ? arrival : nil
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
        // The post office refuses a letter it cannot route, and the mock has to
        // refuse it too or the app would look posted here and fail against the
        // real server.
        guard let transit = person.transit else { throw MailStoreError.noRoutableAddress }
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
            expectedDeliveryDate: PostalCalendar.arrival(after: postmark, transit: transit)
        )
        letters.append(letter)
        return letter
    }

    public func revoke(_ id: LetterID) async throws {
        guard let index = letters.firstIndex(where: { $0.id == id }) else {
            throw MailStoreError.unknownLetter(id)
        }
        // The one irreversible moment in the product. Once the box is emptied,
        // there is nothing to take back. Checked against the clock rather than
        // stored state, because nothing in a mock advances a letter at five.
        guard letters[index].isRevocable(asOf: clock.now) else {
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

    /// A letter whose collection time has passed is in the post, whether or not
    /// anything got round to writing that down.
    private func collected(_ letter: Letter) -> Letter {
        guard letter.state == .awaitingCollection,
              let postmark = letter.postmarkDate,
              clock.now >= postmark else { return letter }
        return letter.with(state: .inTransit, collectedAt: postmark)
    }

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

    func with(state: LetterState? = nil, collectedAt: Date? = nil, readAt: Date? = nil) -> Letter {
        Letter(
            id: id,
            correspondentID: correspondentID,
            isOutbound: isOutbound,
            body: body,
            state: state ?? self.state,
            writtenAt: writtenAt,
            collectedAt: collectedAt ?? self.collectedAt,
            postmarkDate: postmarkDate,
            expectedDeliveryDate: expectedDeliveryDate,
            deliveredAt: deliveredAt,
            readAt: readAt ?? self.readAt
        )
    }
}
