import SwiftUI
import SlowmailCore

/// Letters you have written that haven't arrived yet.
///
/// The only screen where the app admits something is in motion. It shows where
/// each letter is in postal terms — waiting for collection, or travelling — and
/// never a progress bar, because you cannot watch mail move.
public struct OutboxView: View {
    private let letters: [Letter]
    private let people: [CorrespondentID: Correspondent]
    private let onRevoke: (Letter) -> Void

    public init(
        letters: [Letter],
        people: [CorrespondentID: Correspondent],
        onRevoke: @escaping (Letter) -> Void = { _ in }
    ) {
        self.letters = letters
        self.people = people
        self.onRevoke = onRevoke
    }

    public var body: some View {
        ScreenBackground {
            ScrollingScreen {
                VStack(alignment: .leading, spacing: Theme.Space.loose) {
                    Text("Outbox")
                        .font(Theme.Typeface.screenTitle)

                    if letters.isEmpty {
                        Text("Nothing on its way.")
                            .font(Theme.Typeface.letterGreeting)
                            .padding(.vertical, Theme.Space.generous)
                    } else {
                        VStack(spacing: Theme.Space.snug) {
                            ForEach(letters) { letter in
                                OutboundRow(
                                    letter: letter,
                                    to: people[letter.correspondentID],
                                    onRevoke: { onRevoke(letter) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.regular)
                .padding(.vertical, Theme.Space.loose)
            }
        }
    }
}

public struct OutboundRow: View {
    private let letter: Letter
    private let to: Correspondent?
    private let onRevoke: () -> Void

    public init(letter: Letter, to: Correspondent?, onRevoke: @escaping () -> Void = {}) {
        self.letter = letter
        self.to = to
        self.onRevoke = onRevoke
    }

    public var body: some View {
        LetterSheet {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(to?.name ?? "Unknown recipient")
                    .font(Theme.Typeface.letterGreeting)
                Text(firstLine)
                    .font(Theme.Typeface.supporting)
                    .foregroundStyle(Theme.Palette.inkFaint)
                    .lineLimit(1)
                PostmarkLabel(statusLine)
                if let expected = letter.expectedDeliveryDate {
                    PostmarkLabel(PostalWording.expectedArrival(expected))
                }
                if letter.isRevocable {
                    Button("Fetch it back", action: onRevoke)
                        .buttonStyle(.plain)
                        .font(Theme.Typeface.sectionTitle)
                        .foregroundStyle(Theme.Palette.flag)
                        .padding(.top, Theme.Space.tight)
                }
            }
        }
    }

    /// Your own words are yours to see — this is the only place a body is
    /// previewed, and only for outbound mail.
    private var firstLine: String {
        letter.body.split(separator: "\n").first.map(String.init) ?? letter.body
    }

    private var statusLine: String {
        switch letter.state {
        case .awaitingCollection:
            guard let postmark = letter.postmarkDate else { return "Waiting for collection" }
            let formatter = DateFormatter()
            formatter.calendar = .postal
            formatter.timeZone = Calendar.postal.timeZone
            formatter.dateFormat = "EEEE 'at' h a"
            return "Collected \(formatter.string(from: postmark).lowercased())"
        case .inTransit:
            return letter.postmarkDate.map { PostalWording.postmark($0) } ?? "In transit"
        case .delivered:
            return "Delivered"
        case .revoked:
            return "Fetched back"
        }
    }
}
