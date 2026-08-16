import Foundation

private let earthRadiusMiles = 3_958.7613
private let nonContiguousRegions: Set<String> = ["AK", "HI", "PR"]

public func haversineMiles(
    aLatitude: Double,
    aLongitude: Double,
    bLatitude: Double,
    bLongitude: Double
) -> Double {
    let degreesToRadians = Double.pi / 180
    let dLatitude = (bLatitude - aLatitude) * degreesToRadians
    let dLongitude = (bLongitude - aLongitude) * degreesToRadians
    let value =
        pow(sin(dLatitude / 2), 2)
        + cos(aLatitude * degreesToRadians)
        * cos(bLatitude * degreesToRadians)
        * pow(sin(dLongitude / 2), 2)
    return 2 * earthRadiusMiles * asin(min(1, sqrt(value)))
}

public func baseDomesticTransitDays(
    _ miles: Double,
    sender: Party,
    recipient: Party
) -> Int {
    if sender.isTerritory || recipient.isTerritory {
        return 7
    }
    if sender.region.map(nonContiguousRegions.contains) == true
        || recipient.region.map(nonContiguousRegions.contains) == true
    {
        return 5
    }
    if miles <= 50 {
        return 1
    }
    if miles <= 300 {
        return 2
    }
    if miles <= 1_000 {
        return 3
    }
    if miles <= 1_800 {
        return 4
    }
    return 5
}

private let internationalBands: [(band: InternationalBand, countries: Set<String>)] = [
    (InternationalBand(min: 7, max: 10), ["CA", "MX"]),
    (
        InternationalBand(min: 8, max: 14),
        ["GB", "IE", "FR", "DE", "NL", "BE", "LU", "CH", "AT", "ES", "PT", "IT", "DK", "SE", "NO", "FI", "IS"]
    ),
    (
        InternationalBand(min: 10, max: 16),
        ["PL", "CZ", "SK", "HU", "SI", "HR", "EE", "LV", "LT", "RO", "BG", "GR", "JP", "KR", "SG", "AU", "NZ"]
    ),
    (
        InternationalBand(min: 12, max: 21),
        ["BR", "AR", "CL", "CO", "PE", "UY", "CR", "PA", "AE", "SA", "IL", "TR", "QA", "KW", "IN", "CN", "TH", "VN", "MY", "PH", "ID", "TW", "HK"]
    ),
    (
        InternationalBand(min: 14, max: 25),
        ["ZA", "NG", "KE", "EG", "MA", "GH", "TZ", "UG", "ET", "SN", "FJ", "PG", "WS", "TO", "VU", "SB", "MV", "SC", "MU"]
    ),
]

public func internationalBand(countryCode: String) -> InternationalBand {
    let normalized = countryCode.uppercased()
    return internationalBands.first { $0.countries.contains(normalized) }?.band
        ?? InternationalBand(min: 12, max: 21)
}

public func internationalTransitDays(
    messageId: String,
    destinationCountry: String
) throws -> Int {
    let band = internationalBand(countryCode: destinationCountry)
    return try seededIntInRange(
        min: band.min,
        max: band.max,
        namespace: "intl-transit",
        parts: [messageId]
    )
}
