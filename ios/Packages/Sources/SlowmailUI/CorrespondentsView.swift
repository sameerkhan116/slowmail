import SwiftUI
import SlowmailCore

/// The people you write to. Short by design — this is not a contact list you
/// scroll, it is the handful of people worth a letter.
public struct CorrespondentsView: View {
    private let people: [Correspondent]
    private let onSelect: (Correspondent) -> Void

    public init(people: [Correspondent], onSelect: @escaping (Correspondent) -> Void = { _ in }) {
        self.people = people
        self.onSelect = onSelect
    }

    public var body: some View {
        ScreenBackground {
            ScrollingScreen {
                VStack(alignment: .leading, spacing: Theme.Space.loose) {
                    Text("Correspondents")
                        .font(Theme.Typeface.screenTitle)
                    VStack(spacing: Theme.Space.snug) {
                        ForEach(people) { person in
                            Button { onSelect(person) } label: {
                                LetterSheet {
                                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                                        Text(person.name)
                                            .font(Theme.Typeface.letterGreeting)
                                        Text(person.cityLabel)
                                            .font(Theme.Typeface.supporting)
                                            .foregroundStyle(Theme.Palette.inkFaint)
                                        PostmarkLabel(PostalWording.routing(
                                            miles: person.milesAway,
                                            days: person.typicalTransitDays))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.regular)
                .padding(.vertical, Theme.Space.loose)
            }
        }
    }
}

/// Everything exchanged with one person, oldest first, so it reads like a
/// bundle of letters tied with string rather than a chat log.
public struct CorrespondenceView: View {
    private let person: Correspondent
    private let letters: [Letter]
    private let now: Date
    private let onOpen: (Letter) -> Void

    public init(
        person: Correspondent,
        letters: [Letter],
        now: Date,
        onOpen: @escaping (Letter) -> Void = { _ in }
    ) {
        self.person = person
        self.letters = letters
        self.now = now
        self.onOpen = onOpen
    }

    public var body: some View {
        ScreenBackground {
            ScrollingScreen {
                VStack(alignment: .leading, spacing: Theme.Space.loose) {
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        Text(person.name)
                            .font(Theme.Typeface.screenTitle)
                        Text(person.cityLabel)
                            .font(Theme.Typeface.supporting)
                            .foregroundStyle(Theme.Palette.inkFaint)
                        PostmarkLabel(PostalWording.routing(
                            miles: person.milesAway, days: person.typicalTransitDays))
                    }

                    VStack(spacing: Theme.Space.regular) {
                        ForEach(letters) { letter in
                            Button { onOpen(letter) } label: {
                                CorrespondenceRow(letter: letter, now: now)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.regular)
                .padding(.vertical, Theme.Space.loose)
            }
        }
    }
}

/// Direction is shown by inset and a label, not by left/right bubbles.
public struct CorrespondenceRow: View {
    private let letter: Letter
    private let now: Date

    public init(letter: Letter, now: Date) {
        self.letter = letter
        self.now = now
    }

    public var body: some View {
        HStack(spacing: 0) {
            if letter.isOutbound { Spacer(minLength: Theme.Space.generous) }
            LetterSheet(isUnread: letter.isUnread) {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    PostmarkLabel(letter.isOutbound ? "You wrote" : "They wrote")
                    Text(letter.body)
                        .font(Theme.Typeface.letterBody)
                        .lineLimit(3)
                    PostmarkLabel(dateLine)
                }
            }
            if !letter.isOutbound { Spacer(minLength: Theme.Space.generous) }
        }
    }

    private var dateLine: String {
        if let delivered = letter.deliveredAt { return PostalWording.arrivedOn(delivered, now: now) }
        if let expected = letter.expectedDeliveryDate { return PostalWording.expectedArrival(expected) }
        return PostalWording.postmark(letter.writtenAt)
    }
}
