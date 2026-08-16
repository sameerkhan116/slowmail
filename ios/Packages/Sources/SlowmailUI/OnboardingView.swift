import SwiftUI

/// Sets the expectation before anyone writes anything. If someone arrives
/// expecting instant messaging, this is the screen that has to correct them.
public struct OnboardingView: View {
    private let onContinue: () -> Void

    public init(onContinue: @escaping () -> Void = {}) {
        self.onContinue = onContinue
    }

    private static let promises: [(String, String)] = [
        ("Once a day", "The carrier comes once, sometime between nine and five. That's the whole day's post."),
        ("Posted by five", "Anything written before five o'clock goes out today. After that it waits for tomorrow's collection."),
        ("Sundays off", "No collection, no delivery, no exceptions. Same for federal holidays."),
        ("Distance is real", "Across town is a day. Across the country is most of a week. Tokyo is a fortnight."),
    ]

    public var body: some View {
        ScreenBackground {
            ScrollingScreen {
                VStack(alignment: .leading, spacing: Theme.Space.loose) {
                    VStack(alignment: .leading, spacing: Theme.Space.snug) {
                        Text("Slowmail")
                            .font(Theme.Typeface.screenTitle)
                        Text("Letters that travel at the speed of post.")
                            .font(Theme.Typeface.letterGreeting)
                            .foregroundStyle(Theme.Palette.inkFaint)
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.regular) {
                        ForEach(Self.promises, id: \.0) { promise in
                            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                                PostmarkLabel(promise.0)
                                Text(promise.1)
                                    .font(Theme.Typeface.letterBody)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Button(action: onContinue) {
                        Text("Start writing")
                            .font(Theme.Typeface.sectionTitle)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.snug)
                            .foregroundStyle(Theme.Palette.paper)
                    }
                    .buttonStyle(.plain)
                    .background(Theme.Palette.ink)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .padding(.horizontal, Theme.Space.loose)
                .padding(.vertical, Theme.Space.generous)
            }
        }
    }
}
