import SwiftUI
import SlowmailCore

public struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    @State private var openLetter: Letter?
    @State private var composing: Correspondent?
    /// Kept per correspondent. One shared buffer would carry a half-written
    /// letter for one person into the composer for another, which is the one
    /// mistake this app has no way to undo once the box is emptied.
    @State private var drafts = DraftLedger()
    @State private var isPosting = false


    public init(store: any MailStore, clock: any Clock) {
        _model = State(initialValue: AppModel(store: store, clock: clock))
    }

    public var body: some View {
        TabView {
            mailboxTab
                .tabItem { Label("Mailbox", systemImage: "tray") }
            outboxTab
                .tabItem { Label("Outbox", systemImage: "paperplane") }
            correspondentsTab
                .tabItem { Label("People", systemImage: "person.2") }
        }
        .task { await model.load() }
        // The interesting moments in this app happen while nobody is looking:
        // five o'clock passes, the carrier comes. Without this the mailbox shown
        // at nine in the morning is still on screen at six in the evening.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.load() }
        }
        // Coming back to a foregrounded app is only half of it. Someone who
        // leaves the mailbox open at nine in the morning must still see the
        // post appear when the carrier reaches them, without touching anything.
        .task(id: model.nextBoundary) {
            guard let boundary = model.nextBoundary else { return }
            let seconds = boundary.timeIntervalSince(model.now)
            guard seconds > 0 else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await model.load()
        }
        .sheet(item: $openLetter) { letter in
            LetterReaderView(
                letter: letter,
                from: model.person(letter.correspondentID),
                now: model.now,
                onReply: {
                    composing = model.person(letter.correspondentID)
                    openLetter = nil
                }
            )
            .task { await model.markRead(letter.id) }
        }
        .onChange(of: composing?.id) { _, opened in
            // A new sheet is a new writing session. Closing one is not, so a
            // post in flight when the sender walks away still tidies up after
            // itself.
            if opened != nil { drafts.openComposer() }
        }
        .sheet(item: $composing) { person in
            WriteView(
                body: draftBinding(for: person.id),
                recipient: person,
                nextCollection: PostalCalendar.nextCollection(after: model.now),
                estimatedArrival: person.transit.map {
                    PostalCalendar.arrival(
                        after: PostalCalendar.nextCollection(after: model.now), transit: $0)
                },
                now: model.now,
                isPosting: isPosting,
                alreadyPosted: drafts.isAlreadyPosted(person.id),
                onPost: { post(to: person) }
            )
        }
    }

    private func draftBinding(for id: CorrespondentID) -> Binding<String> {
        Binding(
            get: { drafts.body(for: id) },
            set: { drafts.setBody($0, for: id) }
        )
    }

    /// Guarded because a second tap while the first post is in flight would put
    /// two copies of the same letter in the box, and neither can be recalled
    /// after five.
    private func post(to person: Correspondent) {
        guard !isPosting else { return }
        let body = drafts.body(for: person.id)
        guard drafts.canPost(person.id) else { return }
        let sent = drafts.currentGeneration
        isPosting = true
        Task {
            defer { isPosting = false }
            guard await model.post(Draft(correspondentID: person.id, body: body)) != nil else {
                return  // On failure the draft is left exactly where it was.
            }
            // The composer can be dismissed and reopened while the post is in
            // flight. Matching on the text is not enough: reopening the same
            // person and retyping the same words is indistinguishable from
            // never having left, and clearing then would delete a draft the
            // sender is still writing. Only the session that sent may clear it.
            if drafts.completePost(of: body, to: person.id, sentUnder: sent) {
                composing = nil
            }
        }
    }

    private var peopleByID: [CorrespondentID: Correspondent] {
        Dictionary(uniqueKeysWithValues: model.correspondents.map { ($0.id, $0) })
    }

    private var mailboxTab: some View {
        MailboxView(
            letters: model.mailbox,
            people: peopleByID,
            now: model.now,
            carrierExpected: model.carrierExpected,
            onOpen: { openLetter = $0 }
        )
    }

    private var outboxTab: some View {
        OutboxView(
            letters: model.outbox,
            people: peopleByID,
            now: model.now,
            onRevoke: { letter in Task { await model.revoke(letter.id) } }
        )
    }

    private var correspondentsTab: some View {
        CorrespondentsView(
            people: model.correspondents,
            onSelect: { composing = $0 }
        )
    }
}
