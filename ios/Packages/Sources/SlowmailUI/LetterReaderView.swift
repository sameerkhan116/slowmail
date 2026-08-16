import SwiftUI
import SlowmailCore

/// A letter, opened. Full width, serif, generous margins, and nothing else on
/// screen competing for attention.
public struct LetterReaderView: View {
    private let letter: Letter
    private let from: Correspondent?
    private let now: Date
    private let onReply: () -> Void

    public init(
        letter: Letter,
        from: Correspondent?,
        now: Date,
        onReply: @escaping () -> Void = {}
    ) {
        self.letter = letter
        self.from = from
        self.now = now
        self.onReply = onReply
    }

    public var body: some View {
        ScreenBackground {
            ScrollingScreen {
                VStack(alignment: .leading, spacing: Theme.Space.loose) {
                    heading
                    Text(letter.body)
                        .font(Theme.Typeface.letterBody)
                        .lineSpacing(Theme.Space.tight)
                        .textSelection(.enabled)
                    Divider().overlay(Theme.Palette.rule)
                    if !letter.isOutbound {
                        Button(action: onReply) {
                            Text("Write back")
                                .font(Theme.Typeface.sectionTitle)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Space.snug)
                        }
                        .buttonStyle(.plain)
                        .background(Theme.Palette.card)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .stroke(Theme.Palette.rule, lineWidth: Theme.Space.hairline)
                        )
                    }
                }
                .padding(.horizontal, Theme.Space.loose)
                .padding(.vertical, Theme.Space.generous)
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(from?.name ?? "Unknown sender")
                .font(Theme.Typeface.screenTitle)
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
}
