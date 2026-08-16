import SwiftUI

private struct RasterisingKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// True when this view tree is being rasterised by `ImageRenderer` rather
    /// than shown in a window.
    ///
    /// `ScrollView` needs a real window to size its content and renders empty
    /// without one, so the screenshot tool sets this and screens lay themselves
    /// out flat instead. Nothing else in the app should read it.
    var isRasterising: Bool {
        get { self[RasterisingKey.self] }
        set { self[RasterisingKey.self] = newValue }
    }
}

/// The vertical body of a screen. Scrolls in the app, lays out flat when
/// rasterised.
public struct ScrollingScreen<Content: View>: View {
    @Environment(\.isRasterising) private var isRasterising
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if isRasterising {
            VStack(spacing: 0) {
                // A ScrollView hands its content the full width; a bare VStack
                // does not, and would centre anything narrower.
                content.frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        } else {
            ScrollView { content }
        }
    }
}
