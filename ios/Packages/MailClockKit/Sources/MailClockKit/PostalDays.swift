public func isPostalDay(_ isoDate: String) throws -> Bool {
    let date = try PostalDate(isoDate)
    if date.weekday == 1 {
        return false
    }
    return try !isObservedHoliday(isoDate)
}

public func postalDayOnOrAfter(_ isoDate: String) throws -> String {
    var date = try PostalDate(isoDate)
    for _ in 0..<30 {
        if try isPostalDay(date.description) {
            return date.description
        }
        date = try date.adding(days: 1)
    }
    throw MailClockError.noDeliveryDay(isoDate)
}

public func nextPostalDay(_ isoDate: String) throws -> String {
    let date = try PostalDate(isoDate)
    return try postalDayOnOrAfter(date.adding(days: 1).description)
}

public func addPostalDays(_ isoDate: String, count: Int) throws -> String {
    guard count >= 0 else {
        throw MailClockError.negativePostalDays(count)
    }
    var cursor = try PostalDate(isoDate).description
    for _ in 0..<count {
        cursor = try nextPostalDay(cursor)
    }
    return cursor
}
