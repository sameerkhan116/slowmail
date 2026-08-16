import SwiftUI
import SlowmailCore

/// The first thing you see: what is in the box right now.
///
/// It shows one day's post and then stops. There is no infinite scroll here on
/// purpose — running out of things to read is the feature.
public struct MailboxView: View {
    private let letters: [Letter]
    private let people: [CorrespondentID: Correspondent]
    private let now: Date
    private let carrierExpected: Date?
    private let onOpen: (Letter) -> Void

    public init(
        letters: [Letter],
        people: [CorrespondentID: Correspondent],
        now: Date,
        carrierExpected: Date?,
        onOpen: @escaping (Letter) -> Void = { _ in }
    ) {
        self.letters = letters
        self.people = people
        self.now = now
        self.carrierExpected = carrierExpected
        self.onOpen = onOpen
    }

    public var body: some View {
        ScreenBackground {
            ScrollingScreen {
                VStack(alignment: .leading, spacing: Theme.Space.loose) {
                    header
                    if letters.isEmpty {
                        emptyBox
                    } else {
                        VStack(spacing: Theme.Space.snug) {
                            ForEach(letters) { letter in
                                Button { onOpen(letter) } label: {
                                    EnvelopeRow(letter: letter, from: people[letter.correspondentID], now: now)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if carrierExpected != nil, !letters.isEmpty {
                        PostmarkLabel(PostalWording.carrierNotYetBeen)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Theme.Space.tight)
                    }
                }
                .padding(.horizontal, Theme.Space.regular)
                .padding(.vertical, Theme.Space.loose)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            PostmarkLabel(dayLine)
            Text("Mailbox")
                .font(Theme.Typeface.screenTitle)
        }
    }

    private var dayLine: String {
        let formatter = DateFormatter()
        formatter.calendar = .postal
        formatter.timeZone = Calendar.postal.timeZone
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: now)
    }

    /// An empty box means two different things depending on whether the round
    /// has happened yet, and saying the wrong one is worse than saying nothing.
    private var emptyBox: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(carrierExpected == nil
                 ? PostalWording.nothingComingToday
                 : PostalWording.postNotHereYet)
                .font(Theme.Typeface.letterGreeting)
            Text(carrierExpected == nil
                 ? PostalWording.emptyMailboxDetail
                 : PostalWording.emptyMailboxWaitingDetail)
                .font(Theme.Typeface.supporting)
                .foregroundStyle(Theme.Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.generous)
    }
}

/// A closed envelope in the pile. Shows who it is from and where it came from —
/// never a preview of the contents, because that would defeat the point.
public struct EnvelopeRow: View {
    private let letter: Letter
    private let from: Correspondent?
    private let now: Date

    public init(letter: Letter, from: Correspondent?, now: Date) {
        self.letter = letter
        self.from = from
        self.now = now
    }

    public var body: some View {
        LetterSheet(isUnread: letter.isUnread) {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                    if letter.isUnread {
                        Circle()
                            .fill(Theme.Palette.flag)
                            .frame(width: Theme.Space.tight, height: Theme.Space.tight)
                    }
                    Text(from?.name ?? "Unknown sender")
                        .font(Theme.Typeface.letterGreeting)
                }
                if let from {
                    Text(from.cityLabel)
                        .font(Theme.Typeface.supporting)
                        .foregroundStyle(Theme.Palette.inkFaint)
                }
                if let postmark = letter.postmarkDate {
                    PostmarkLabel(PostalWording.postmark(postmark))
                }
                if let arrived = letter.deliveredAt {
                    PostmarkLabel(PostalWording.arrivedOn(arrived, now: now))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [letter.isUnread ? "Unopened letter" : "Letter"]
        if let from { parts.append("from \(from.name), \(from.cityLabel)") }
        if let arrived = letter.deliveredAt { parts.append(PostalWording.arrivedOn(arrived, now: now)) }
        return parts.joined(separator: ", ")
    }
}
