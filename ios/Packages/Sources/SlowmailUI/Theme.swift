import SwiftUI

/// The whole visual vocabulary. Views never reach for a raw colour, font, or
/// spacing value — if something is missing here, it gets added here.
public enum Theme {
    public enum Palette {
        /// Unbleached envelope. Behind everything.
        public static let paper = Color.adaptive(
            light: (0.965, 0.945, 0.902), dark: (0.098, 0.094, 0.086))
        /// A letter laid on the surface.
        public static let card = Color.adaptive(
            light: (0.992, 0.980, 0.953), dark: (0.149, 0.141, 0.129))
        public static let ink = Color.adaptive(
            light: (0.129, 0.118, 0.102), dark: (0.925, 0.906, 0.867))
        /// Postmark grey, for dates and status lines.
        public static let inkFaint = Color.adaptive(
            light: (0.451, 0.420, 0.376), dark: (0.612, 0.588, 0.541))
        /// The mailbox flag, and nothing else. Scarcity is what gives it meaning.
        public static let flag = Color.adaptive(
            light: (0.706, 0.216, 0.157), dark: (0.855, 0.325, 0.259))
        public static let rule = Color.adaptive(
            light: (0.851, 0.816, 0.757), dark: (0.259, 0.243, 0.220))
    }

    public enum Typeface {
        /// Letter bodies. Serif, because a letter is not a chat message.
        public static let letterBody = Font.system(.body, design: .serif)
        public static let letterGreeting = Font.system(.title3, design: .serif)
        public static let screenTitle = Font.system(.largeTitle, design: .serif).weight(.medium)
        public static let sectionTitle = Font.system(.subheadline).weight(.semibold)
        public static let postmark = Font.system(.caption, design: .monospaced)
        public static let supporting = Font.system(.footnote)
    }

    public enum Space {
        public static let hairline: CGFloat = 1
        public static let tight: CGFloat = 6
        public static let snug: CGFloat = 12
        public static let regular: CGFloat = 18
        public static let loose: CGFloat = 28
        public static let generous: CGFloat = 40
    }

    public enum Radius {
        public static let letter: CGFloat = 4
        public static let control: CGFloat = 10
    }
}

/// A sheet of paper with something written on it.
public struct LetterSheet<Content: View>: View {
    private let content: Content
    private let isUnread: Bool

    public init(isUnread: Bool = false, @ViewBuilder content: () -> Content) {
        self.isUnread = isUnread
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.regular)
            .background(Theme.Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.letter))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.letter)
                    .stroke(
                        isUnread ? Theme.Palette.flag.opacity(0.55) : Theme.Palette.rule,
                        lineWidth: Theme.Space.hairline
                    )
            )
    }
}

/// The uppercase, letter-spaced line used for postmarks and section headers.
public struct PostmarkLabel: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text.uppercased())
            .font(Theme.Typeface.postmark)
            .tracking(1.1)
            .foregroundStyle(Theme.Palette.inkFaint)
    }
}

public struct ScreenBackground<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ZStack {
            Theme.Palette.paper.ignoresSafeArea()
            content
        }
        .tint(Theme.Palette.ink)
        .foregroundStyle(Theme.Palette.ink)
    }
}
