import SwiftUI
import SlowmailCore
import SlowmailUI

/// The shipping app is this thin on purpose: everything worth testing lives in
/// SlowmailCore and SlowmailUI, which build and run without Xcode.
@main
struct SlowmailApp: App {
    private let clock = SystemClock()

    var body: some Scene {
        WindowGroup {
            RootView(store: MockMailStore(clock: clock), clock: clock)
        }
    }
}
