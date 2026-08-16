import Foundation

/// FNV-1a over UTF-16 code units.
///
/// The unit matters and is not arbitrary: the server's scheduling engine hashes
/// JavaScript strings, which are UTF-16. Hashing UTF-8 here would agree on every
/// ASCII input and diverge silently the moment a name or id carries an accent,
/// which would move a delivery time rather than raise an error.
enum Hashing {
    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for unit in text.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16_777_619
        }
        return hash
    }

    /// A fraction in [0, 1) derived from a namespaced key.
    static func unitInterval(_ parts: String...) -> Double {
        let key = parts.joined(separator: "\u{0}")
        return Double(fnv1a(key) % 1_000_000) / 1_000_000.0
    }
}
