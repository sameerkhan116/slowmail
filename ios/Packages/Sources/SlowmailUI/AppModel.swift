import Foundation
import Observation
import SlowmailCore

/// The one place the app holds loaded state.
///
/// Views never call the store directly; they read what has been loaded and ask
/// the model to change something. That keeps every screen renderable from plain
/// values, which is what makes the headless screenshots possible.
@MainActor
@Observable
public final class AppModel {
    public private(set) var mailbox: [Letter] = []
    public private(set) var outbox: [Letter] = []
    public private(set) var correspondents: [Correspondent] = []
    public private(set) var carrierExpected: Date?
    public private(set) var lastError: String?

    private let store: any MailStore
    /// Today's round whether or not it has passed; the skew window needs it
    /// after `carrierExpected` has gone nil.
    private var todaysRound: Date?
    private let clock: any Clock

    public init(store: any MailStore, clock: any Clock) {
        self.store = store
        self.clock = clock
    }

    public var now: Date { clock.now }

    /// The next instant at which what the app is showing becomes wrong: the
    /// carrier's round if it has not happened yet, otherwise the five o'clock
    /// collection. Views wait on it so a mailbox left open on screen still
    /// fills when the post comes.
    public var nextBoundary: Date? {
        let collection = PostalCalendar.nextCollection(after: clock.now)
        if let carrier = carrierExpected, carrier > clock.now {
            return min(carrier, collection)
        }
        // The round has been, as far as this device can tell. It works that
        // instant out from its own copy of the timezone database, which can put
        // it up to an hour ahead of the server's — long enough to stop watching
        // just before the mail it is waiting for actually lands. So keep
        // checking until the skew window has passed.
        //
        // The round comes from the store, which knows the signed-in id and the
        // recipient's profile zone. Working it out here instead used neither:
        // the id defaulted to the fixture's and the zone to the device's, so
        // the window could close before the real round on a travelling device.
        if let round = todaysRound {
            let settled = round.addingTimeInterval(PostalCalendar.maximumRoundSkew)
            if settled > clock.now { return min(settled, collection) }
        }
        return collection
    }

    public func load() async {
        do {
            mailbox = try await store.mailbox()
            outbox = try await store.outbox()
            correspondents = try await store.correspondents()
            carrierExpected = try await store.carrierExpected(on: clock.now)
            todaysRound = try await store.carrierRound(on: clock.now)
            lastError = nil
        } catch {
            lastError = "Couldn't reach the post office."
        }
    }

    public func correspondence(with id: CorrespondentID) async -> [Letter] {
        (try? await store.correspondence(with: id)) ?? []
    }

    public func person(_ id: CorrespondentID) -> Correspondent? {
        correspondents.first { $0.id == id }
    }

    public func post(_ draft: Draft) async -> Letter? {
        do {
            let letter = try await store.write(draft)
            await load()
            return letter
        } catch {
            lastError = "That letter couldn't be posted."
            return nil
        }
    }

    public func revoke(_ id: LetterID) async {
        do {
            try await store.revoke(id)
            await load()
        } catch MailStoreError.alreadyCollected {
            lastError = "The carrier already has it."
            await load()
        } catch {
            lastError = "Couldn't fetch that letter back."
        }
    }

    public func markRead(_ id: LetterID) async {
        try? await store.markRead(id)
        await load()
    }

    public func dismissError() { lastError = nil }
}
