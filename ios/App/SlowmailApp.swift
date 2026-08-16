import SwiftUI
import SlowmailCore
import SlowmailUI

/// The shipping app is this thin on purpose: everything worth testing lives in
/// SlowmailCore and SlowmailUI, which build and run without Xcode.
@main
struct SlowmailApp: App {
    private let clock = SystemClock()
    private let configuration = (try? MailStoreConfiguration.resolve()) ?? .demo

    var body: some Scene {
        WindowGroup {
            // No sign-in screen exists yet, so a configured server has no
            // session to present and `store` throws. Falling back to fixtures
            // here is deliberate and visible: the demo says plainly that it is
            // holding letters with this device's clock.
            if let store = try? configuration.store(clock: clock) {
                RootView(store: store, clock: clock)
            } else {
                RootView(store: MockMailStore(clock: clock), clock: clock)
            }
        }
    }
}
