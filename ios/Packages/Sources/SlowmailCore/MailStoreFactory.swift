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
    /// Neither argument has a default, deliberately. `bundle` used to default
    /// to an empty dictionary, which meant the documented Info.plist keys were
    /// never read by anything that ships and every build quietly ran on
    /// fixtures. A test could only have caught that by observing a default it
    /// cannot see, so the default is gone instead: every caller now names where
    /// its configuration comes from, and the old bug will not compile.
    ///
    /// A half-configuration — a URL with no key, or a key with no URL — is
    /// `nil` rather than `demo`, because it means somebody intended to reach a
    /// server and the build should not quietly stop trying.
    public static func resolve(
        environment: [String: String],
        bundle: [String: String]
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

public extension MailStoreConfiguration {
    /// Wording for the screen a misconfigured build shows. Says which key is
    /// wrong, because the person reading it is the person who can fix it.
    static func explain(_ error: any Error) -> String {
        switch error as? MailStoreConfigurationError {
        case let .incomplete(missing):
            return "\(missing) is not set. Set both it and the other, or neither for the demo."
        case let .badURL(url):
            return "\(url) is not an https address. Letters and the sign-in token travel on it."
        case .notSignedIn:
            return "A post office is configured, but nobody is signed in. "
                + "Sign-in has not been built yet."
        case nil:
            return "\(error)"
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


public extension Bundle {
    /// The two Info.plist keys a shipped build is configured through.
    ///
    /// Defaulted into `resolve` rather than read inside it so a test can supply
    /// its own — but defaulted to the *real* bundle, because a default of `[:]`
    /// meant the documented configuration was never read by anything that ships
    /// and every build silently ran on fixtures.
    var slowmailConfiguration: [String: String] {
        Self.slowmailConfiguration { object(forInfoDictionaryKey: $0) }
    }

    /// Split from the property so the extraction can be tested against a source
    /// that is not `Bundle.main`, which a test process cannot populate.
    static func slowmailConfiguration(_ lookup: (String) -> Any?) -> [String: String] {
        ["SlowmailSupabaseURL", "SlowmailSupabaseAnonKey"].reduce(into: [:]) { found, key in
            if let value = lookup(key) as? String { found[key] = value }
        }
    }
}
