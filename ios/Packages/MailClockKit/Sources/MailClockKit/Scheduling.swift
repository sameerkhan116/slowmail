import Foundation

public let collectionHour = 17
public let arrivalWindowStartHour = 9
public let arrivalWindowEndHour = 17

public func nextCollection(
    writtenAt: String,
    senderTimeZone: String
) throws -> Collection {
    let instant = try parseInstant(writtenAt)
    guard let zone = TimeZone(identifier: senderTimeZone) else {
        throw MailClockError.invalidTimeZone(senderTimeZone)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let components = calendar.dateComponents(
        [.year, .month, .day, .hour],
        from: instant
    )
    let today = try PostalDate(
        year: components.year!,
        month: components.month!,
        day: components.day!
    )
    let madeTodaysPickup =
        try isPostalDay(today.description)
        && components.hour! < collectionHour
    let postmarkDate = madeTodaysPickup
        ? today.description
        : try nextPostalDay(today.description)
    let collectionDate = try PostalDate(postmarkDate)
    let collectedAt = try wallClock(
        collectionDate,
        hour: collectionHour,
        minute: 0,
        timeZone: senderTimeZone
    )
    return Collection(at: formatInstant(collectedAt), postmarkDate: postmarkDate)
}

/// The moment a given recipient's carrier reaches them on a given day.
///
/// Seeded on the person and the date, so the app can ask twice and get the same
/// answer.
///
/// The *minute* is seeded, but the instant is not: turning 13:52 into a point in
/// time needs `timeZone`, and a different zone gives a different point. Callers
/// holding several letters for one recipient on one date must pass the same zone
/// for all of them, or those letters land hours apart and the recipient watches
/// the post arrive twice.
///
/// That is a real hazard wherever the zone is stored per letter rather than per
/// person — a recipient who moves between two postings ends up with two
/// snapshots of the same date. Resolve the zone once per recipient per date and
/// reuse it; do not pass a zone that travels with the letter.
public func carrierArrival(
    userId: String,
    localDate: String,
    timeZone: String
) throws -> String {
    let windowMinutes = (arrivalWindowEndHour - arrivalWindowStartHour) * 60
    let offset = try seededIntInRange(
        min: 0,
        max: windowMinutes - 1,
        namespace: "carrier-arrival",
        parts: [userId, localDate]
    )
    let hour = arrivalWindowStartHour + offset / 60
    let instant = try wallClock(
        PostalDate(localDate),
        hour: hour,
        minute: offset % 60,
        timeZone: timeZone
    )
    return formatInstant(instant)
}

public func transitJitter(messageId: String) -> Int {
    let unit = seededUnitParts(
        namespace: "transit-jitter",
        parts: [messageId]
    )
    if unit < 0.2 {
        return 1
    }
    if unit < 0.3 {
        return -1
    }
    return 0
}

public func rollToDeliveryDay(
    _ isoDate: String,
    countryCode: String
) throws -> String {
    var date = try PostalDate(isoDate)
    for _ in 0..<30 {
        if countryCode.uppercased() == "US" {
            if try isPostalDay(date.description) {
                return date.description
            }
        } else if date.weekday != 1 {
            return date.description
        }
        date = try date.adding(days: 1)
    }
    throw MailClockError.noDeliveryDay(isoDate)
}

public func schedule(_ input: ScheduleInput) throws -> Schedule {
    let collection = try nextCollection(
        writtenAt: input.writtenAt,
        senderTimeZone: input.sender.timeZone
    )
    let isInternational =
        input.sender.countryCode.uppercased()
        != input.recipient.countryCode.uppercased()

    let transitDays: Int
    var deliveryDate: String

    if isInternational {
        transitDays = try internationalTransitDays(
            messageId: input.messageId,
            destinationCountry: input.recipient.countryCode
        )
        let nominal = try PostalDate(collection.postmarkDate)
            .adding(days: transitDays)
            .description
        deliveryDate = try rollToDeliveryDay(
            nominal,
            countryCode: input.recipient.countryCode
        )
    } else {
        let miles = haversineMiles(
            aLatitude: input.sender.latitude,
            aLongitude: input.sender.longitude,
            bLatitude: input.recipient.latitude,
            bLongitude: input.recipient.longitude
        )
        let base = baseDomesticTransitDays(
            miles,
            sender: input.sender,
            recipient: input.recipient.party
        )
        transitDays = max(1, base + transitJitter(messageId: input.messageId))
        deliveryDate = try addPostalDays(
            collection.postmarkDate,
            count: transitDays
        )
    }

    var deliverAt = try carrierArrival(
        userId: input.recipient.userId,
        localDate: deliveryDate,
        timeZone: input.recipient.timeZone
    )
    let collectedInstant = try parseInstant(collection.at)
    var guardCount = 0
    while try parseInstant(deliverAt) <= collectedInstant {
        guardCount += 1
        if guardCount > 30 {
            throw MailClockError.noDeliveryDay(deliveryDate)
        }
        let nextDate = try PostalDate(deliveryDate).adding(days: 1)
        deliveryDate = try rollToDeliveryDay(
            nextDate.description,
            countryCode: input.recipient.countryCode
        )
        deliverAt = try carrierArrival(
            userId: input.recipient.userId,
            localDate: deliveryDate,
            timeZone: input.recipient.timeZone
        )
    }

    return Schedule(
        collectedAt: collection.at,
        postmarkDate: collection.postmarkDate,
        transitDays: transitDays,
        deliveryDate: deliveryDate,
        deliverAt: deliverAt,
        isInternational: isInternational
    )
}
