import SwiftUI
import SlowmailCore

/// Shown when the app cannot tell where its post office is.
///
/// It exists so that a misconfigured build says so. The alternative — falling
/// back to fixtures — produces an app that looks like it is working and shows
/// the reader letters nobody wrote.
public struct ConfigurationFailureView: View {
    private let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var body: some View {
        VStack(spacing: Theme.Space.regular) {
            Text("No post office")
                .font(Theme.Typeface.screenTitle)
            Text(reason)
                .font(Theme.Typeface.supporting)
                .foregroundStyle(Theme.Palette.inkFaint)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.generous)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.paper)
    }
}

public extension View {
    /// Marks fixture data as fixture data, so a demo build is never mistaken
    /// for someone's actual correspondence.
    @ViewBuilder
    func demoBanner(_ isDemo: Bool) -> some View {
        if isDemo {
            safeAreaInset(edge: .top) {
                Text("Demo — these letters are made up")
                    .font(Theme.Typeface.supporting)
                    .padding(.vertical, Theme.Space.tight)
                    .frame(maxWidth: .infinity)
                    .background(Theme.Palette.inkFaint.opacity(0.15))
            }
        } else {
            self
        }
    }
}
