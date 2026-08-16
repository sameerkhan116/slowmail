import Foundation

/// Where the app gets its post from.
///
/// Two stores exist and they are not interchangeable in the way that phrase
/// usually implies. `MockMailStore` holds letters in memory and enforces the
/// delivery hold with the device's own clock, which is fine for a demo and
/// worthless as a guarantee — the device's clock belongs to the reader. The
/// real hold is a row-level security predicate in Postgres, and only
/// `SupabaseMailStore` is behind it.
///
/// The app therefore prefers the server whenever it is configured, and says so
/// rather than falling back silently: a build that believes it is talking to a
/// server but is not would show a reader mail that hasn't been delivered.
public enum MailStoreConfiguration: Sendable, Equatable {
    /// Fixtures on the device. No server, no hold worth the name.
    case demo
    case supabase(url: URL, apiKey: String)

    /// Read from the environment first so a debug run can point somewhere, then
    /// the bundle's Info.plist, which is how a shipped build is configured.
    ///
    /// A half-configuration — a URL with no key, or a key with no URL — is
    /// `nil` rather than `demo`, because it means somebody intended to reach a
    /// server and the build should not quietly stop trying.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: [String: String] = [:]
    ) throws -> MailStoreConfiguration {
        let urlText = environment["SLOWMAIL_SUPABASE_URL"] ?? bundle["SlowmailSupabaseURL"]
        let key = environment["SLOWMAIL_SUPABASE_ANON_KEY"] ?? bundle["SlowmailSupabaseAnonKey"]

        switch (urlText?.nonEmpty, key?.nonEmpty) {
        case (nil, nil):
            return .demo
        case let (url?, key?):
            guard let parsed = URL(string: url), parsed.scheme == "https" else {
                throw MailStoreConfigurationError.badURL(url)
            }
            return .supabase(url: parsed, apiKey: key)
        case (nil, _?):
            throw MailStoreConfigurationError.incomplete(missing: "SLOWMAIL_SUPABASE_URL")
        case (_?, nil):
            throw MailStoreConfigurationError.incomplete(missing: "SLOWMAIL_SUPABASE_ANON_KEY")
        }
    }
}

public enum MailStoreConfigurationError: Error, Equatable {
    /// Half a configuration is a mistake, not a request for the demo.
    case incomplete(missing: String)
    /// Plain http would put the letters and the token on the wire.
    case badURL(String)
    /// The server is configured but nobody is signed in yet.
    case notSignedIn
}

extension MailStoreConfiguration {
    /// Builds the store this configuration describes.
    ///
    /// The Supabase case needs a signed-in session, because every request
    /// carries the reader's own token and row-level security is what decides
    /// which letters have been delivered. There is no sign-in screen in this
    /// build, so a configured server with no session is an error rather than a
    /// silent drop back to fixtures.
    public func store(clock: any Clock, tokens: (any TokenProvider)? = nil) throws -> any MailStore {
        switch self {
        case .demo:
            return MockMailStore(clock: clock)
        case let .supabase(url, apiKey):
            guard let tokens else { throw MailStoreConfigurationError.notSignedIn }
            return SupabaseMailStore(
                baseURL: url, apiKey: apiKey, tokens: tokens, clock: clock)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
