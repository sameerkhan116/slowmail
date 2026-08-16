import Foundation

public struct Party: Sendable, Equatable {
    public let timeZone: String
    public let latitude: Double
    public let longitude: Double
    public let countryCode: String
    public let region: String?
    public let isTerritory: Bool

    public init(
        timeZone: String,
        latitude: Double,
        longitude: Double,
        countryCode: String,
        region: String? = nil,
        isTerritory: Bool = false
    ) {
        self.timeZone = timeZone
        self.latitude = latitude
        self.longitude = longitude
        self.countryCode = countryCode
        self.region = region
        self.isTerritory = isTerritory
    }
}

public struct Recipient: Sendable, Equatable {
    public let timeZone: String
    public let latitude: Double
    public let longitude: Double
    public let countryCode: String
    public let region: String?
    public let isTerritory: Bool
    public let userId: String

    public init(
        timeZone: String,
        latitude: Double,
        longitude: Double,
        countryCode: String,
        region: String? = nil,
        isTerritory: Bool = false,
        userId: String
    ) {
        self.timeZone = timeZone
        self.latitude = latitude
        self.longitude = longitude
        self.countryCode = countryCode
        self.region = region
        self.isTerritory = isTerritory
        self.userId = userId
    }

    var party: Party {
        Party(
            timeZone: timeZone,
            latitude: latitude,
            longitude: longitude,
            countryCode: countryCode,
            region: region,
            isTerritory: isTerritory
        )
    }
}

public struct ScheduleInput: Sendable, Equatable {
    public let messageId: String
    public let writtenAt: String
    public let sender: Party
    public let recipient: Recipient

    public init(messageId: String, writtenAt: String, sender: Party, recipient: Recipient) {
        self.messageId = messageId
        self.writtenAt = writtenAt
        self.sender = sender
        self.recipient = recipient
    }
}

public struct Schedule: Sendable, Equatable {
    public let collectedAt: String
    public let postmarkDate: String
    public let transitDays: Int
    public let deliveryDate: String
    public let deliverAt: String
    public let isInternational: Bool

    public init(
        collectedAt: String,
        postmarkDate: String,
        transitDays: Int,
        deliveryDate: String,
        deliverAt: String,
        isInternational: Bool
    ) {
        self.collectedAt = collectedAt
        self.postmarkDate = postmarkDate
        self.transitDays = transitDays
        self.deliveryDate = deliveryDate
        self.deliverAt = deliverAt
        self.isInternational = isInternational
    }
}

public struct Collection: Sendable, Equatable {
    public let at: String
    public let postmarkDate: String

    public init(at: String, postmarkDate: String) {
        self.at = at
        self.postmarkDate = postmarkDate
    }
}

public struct InternationalBand: Sendable, Equatable {
    public let min: Int
    public let max: Int

    public init(min: Int, max: Int) {
        self.min = min
        self.max = max
    }
}

public enum MailClockError: Error, Equatable, Sendable {
    case invalidDate(String)
    case invalidInstant(String)
    case invalidTimeZone(String)
    case invalidRange(min: Int, max: Int)
    case negativePostalDays(Int)
    case noDeliveryDay(String)
}
