import Foundation

private let fixedHolidays = [
    (month: 1, day: 1),
    (month: 6, day: 19),
    (month: 7, day: 4),
    (month: 11, day: 11),
    (month: 12, day: 25),
]

private let floatingHolidays = [
    (month: 1, weekday: 2, nth: 3),
    (month: 2, weekday: 2, nth: 3),
    (month: 5, weekday: 2, nth: -1),
    (month: 9, weekday: 2, nth: 1),
    (month: 10, weekday: 2, nth: 2),
    (month: 11, weekday: 5, nth: 4),
]

public func observedHolidays(year: Int) throws -> Set<String> {
    var dates = Set<PostalDate>()

    for holiday in fixedHolidays {
        let nominal = try PostalDate(
            year: year,
            month: holiday.month,
            day: holiday.day
        )
        dates.insert(nominal)
        if nominal.weekday == 7 {
            dates.insert(try nominal.adding(days: -1))
        } else if nominal.weekday == 1 {
            dates.insert(try nominal.adding(days: 1))
        }
    }

    for holiday in floatingHolidays {
        dates.insert(
            try nthWeekdayOfMonth(
                year: year,
                month: holiday.month,
                weekday: holiday.weekday,
                nth: holiday.nth
            )
        )
    }

    let nextNewYear = try PostalDate(year: year + 1, month: 1, day: 1)
    if nextNewYear.weekday == 7 {
        dates.insert(try nextNewYear.adding(days: -1))
    }

    return Set(dates.lazy.filter { $0.year == year }.map(\.description))
}

public func isObservedHoliday(_ isoDate: String) throws -> Bool {
    let date = try PostalDate(isoDate)
    return try observedHolidays(year: date.year).contains(isoDate)
}

private func nthWeekdayOfMonth(
    year: Int,
    month: Int,
    weekday: Int,
    nth: Int
) throws -> PostalDate {
    if nth > 0 {
        let first = try PostalDate(year: year, month: month, day: 1)
        let delta = (weekday - first.weekday + 7) % 7
        return try first.adding(days: delta + (nth - 1) * 7)
    }

    let firstOfNextMonth: PostalDate
    if month == 12 {
        firstOfNextMonth = try PostalDate(year: year + 1, month: 1, day: 1)
    } else {
        firstOfNextMonth = try PostalDate(year: year, month: month + 1, day: 1)
    }
    let last = try firstOfNextMonth.adding(days: -1)
    let delta = (last.weekday - weekday + 7) % 7
    return try last.adding(days: -delta)
}
