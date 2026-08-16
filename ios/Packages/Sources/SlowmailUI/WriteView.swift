import SwiftUI
import SlowmailCore

/// Writing a letter.
///
/// The send button says "Post" and the screen tells you, before you commit,
/// when the box is next emptied and roughly when it will land. Nothing about
/// this screen suggests the other person is waiting on the other end.
public struct WriteView: View {
    @Environment(\.isRasterising) private var isRasterising
    @Binding private var body_: String
    private let recipient: Correspondent?
    private let nextCollection: Date
    private let estimatedArrival: Date
    private let now: Date
    private let isPosting: Bool
    private let onPost: () -> Void
    private let onPickRecipient: () -> Void

    public init(
        body: Binding<String>,
        recipient: Correspondent?,
        nextCollection: Date,
        estimatedArrival: Date,
        now: Date,
        isPosting: Bool = false,
        onPost: @escaping () -> Void = {},
        onPickRecipient: @escaping () -> Void = {}
    ) {
        self._body_ = body
        self.recipient = recipient
        self.nextCollection = nextCollection
        self.estimatedArrival = estimatedArrival
        self.now = now
        self.isPosting = isPosting
        self.onPost = onPost
        self.onPickRecipient = onPickRecipient
    }

    public var body: some View {
        ScreenBackground {
            VStack(alignment: .leading, spacing: Theme.Space.regular) {
                recipientLine
                Divider().overlay(Theme.Palette.rule)
                editor
                Divider().overlay(Theme.Palette.rule)
                schedule
                postButton
            }
            .padding(.horizontal, Theme.Space.loose)
            .padding(.vertical, Theme.Space.loose)
        }
    }

    private var recipientLine: some View {
        Button(action: onPickRecipient) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                PostmarkLabel("To")
                Text(recipient?.name ?? "Choose someone")
                    .font(Theme.Typeface.letterGreeting)
                Spacer()
                if let recipient {
                    Text(PostalWording.distance(miles: recipient.milesAway))
                        .font(Theme.Typeface.supporting)
                        .foregroundStyle(Theme.Palette.inkFaint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if body_.isEmpty {
                Text(Self.placeholder)
                    .font(Theme.Typeface.letterBody)
                    .foregroundStyle(Theme.Palette.inkFaint)
                    .padding(.top, Theme.Space.tight)
            }
            if isRasterising {
                // TextEditor is backed by a platform text view and draws a
                // placeholder glyph when rasterised outside a window, so the
                // screenshot shows the text laid out instead.
                Text(body_)
                    .font(Theme.Typeface.letterBody)
                    .lineSpacing(Theme.Space.tight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Space.tight)
            } else {
                TextEditor(text: $body_)
                    .font(Theme.Typeface.letterBody)
                    .lineSpacing(Theme.Space.tight)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static let placeholder = "Take your time."

    private var schedule: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            PostmarkLabel(collectionLine)
            PostmarkLabel(PostalWording.expectedArrival(estimatedArrival))
        }
    }

    private var collectionLine: String {
        PostalWording.collection(nextCollection, asOf: now)
    }

    private var postButton: some View {
        Button(action: onPost) {
            Text(isPosting ? "Posting" : "Post")
                .font(Theme.Typeface.sectionTitle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.snug)
                .foregroundStyle(Theme.Palette.paper)
        }
        .buttonStyle(.plain)
        .background(canPost ? Theme.Palette.ink : Theme.Palette.inkFaint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .disabled(!canPost)
    }

    private var canPost: Bool {
        !isPosting && recipient != nil
            && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
