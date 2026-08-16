public func fnv1a(_ input: String) -> UInt32 {
    var hash: UInt32 = 0x811c9dc5
    for codeUnit in input.utf16 {
        hash ^= UInt32(codeUnit)
        hash = hash &* 16_777_619
    }
    return hash
}

public func seededHash(namespace: String, parts: String...) -> UInt32 {
    seededHashParts(namespace: namespace, parts: parts)
}

public func seededUnit(namespace: String, parts: String...) -> Double {
    seededUnitParts(namespace: namespace, parts: parts)
}

public func seededIntInRange(
    min: Int,
    max: Int,
    namespace: String,
    parts: String...
) throws -> Int {
    guard max >= min else {
        throw MailClockError.invalidRange(min: min, max: max)
    }
    let span = UInt32(max - min + 1)
    return min + Int(seededHashParts(namespace: namespace, parts: parts) % span)
}

private func seededHashParts(namespace: String, parts: [String]) -> UInt32 {
    fnv1a(([namespace] + parts).joined(separator: "\u{0}"))
}

func seededIntInRange(
    min: Int,
    max: Int,
    namespace: String,
    parts: [String]
) throws -> Int {
    guard max >= min else {
        throw MailClockError.invalidRange(min: min, max: max)
    }
    let span = UInt32(max - min + 1)
    return min + Int(seededHashParts(namespace: namespace, parts: parts) % span)
}

func seededUnitParts(namespace: String, parts: [String]) -> Double {
    Double(seededHashParts(namespace: namespace, parts: parts)) / 4_294_967_296
}
