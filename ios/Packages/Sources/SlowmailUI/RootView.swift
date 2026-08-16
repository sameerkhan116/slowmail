import SwiftUI
import SlowmailCore

public struct RootView: View {
    @State private var model: AppModel
    @State private var openLetter: Letter?
    @State private var composing: Correspondent?
    @State private var draftBody: String = ""

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
        .sheet(item: $composing) { person in
            WriteView(
                body: $draftBody,
                recipient: person,
                nextCollection: PostalCalendar.nextCollection(after: model.now),
                estimatedArrival: PostalCalendar.addingPostalDays(
                    person.typicalTransitDays,
                    to: PostalCalendar.nextCollection(after: model.now)
                ),
                onPost: {
                    let draft = Draft(correspondentID: person.id, body: draftBody)
                    Task {
                        if await model.post(draft) != nil {
                            draftBody = ""
                            composing = nil
                        }
                    }
                }
            )
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
