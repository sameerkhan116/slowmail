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

    /// A hash namespaced by purpose, so that two draws keyed on the same
    /// string — a message id that happens to equal a user id — do not move
    /// together. The NUL separator and the namespace-then-parts order are
    /// part of the wire contract with the server, not an implementation
    /// detail: change either and every seeded time in the app shifts.
    static func seeded(_ namespace: String, _ parts: [String]) -> UInt32 {
        fnv1a(namespace + "\u{0}" + parts.joined(separator: "\u{0}"))
    }

    /// A fraction in [0, 1), over the full 32-bit range.
    static func unitInterval(_ namespace: String, _ parts: String...) -> Double {
        Double(seeded(namespace, parts)) / 4_294_967_296.0
    }

    /// Uniform integer in [min, max], inclusive at both ends.
    static func intInRange(_ min: Int, _ max: Int, _ namespace: String, _ parts: String...) -> Int {
        precondition(max >= min, "empty range")
        let span = UInt32(max - min + 1)
        return min + Int(seeded(namespace, parts) % span)
    }
}
