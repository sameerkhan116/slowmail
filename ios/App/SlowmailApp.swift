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
            switch Self.start(clock: clock) {
            case let .running(store, isDemo):
                RootView(store: store, clock: clock)
                    .demoBanner(isDemo)
            case let .misconfigured(reason):
                // Deliberately not a fallback to fixtures. A build that meant
                // to reach the post office and quietly served made-up letters
                // instead would be indistinguishable, from inside the app, from
                // one that worked.
                ConfigurationFailureView(reason: reason)
            }
        }
    }

    enum Start {
        case running(store: any MailStore, isDemo: Bool)
        case misconfigured(reason: String)
    }

    static func start(clock: any Clock) -> Start {
        do {
            let configuration = try MailStoreConfiguration.resolve(
                environment: ProcessInfo.processInfo.environment,
                bundle: Bundle.main.slowmailConfiguration)
            // No sign-in screen exists yet, so a configured server has no
            // session to present. That is a missing feature, not a reason to
            // show someone fixtures and call it their mail.
            return .running(
                store: try configuration.store(clock: clock),
                isDemo: configuration == .demo)
        } catch {
            return .misconfigured(reason: MailStoreConfiguration.explain(error))
        }
    }
}
