import Foundation

/// A clock the app can move.
///
/// Everything interesting about this product happens over days, so a demo that
/// waits for real time is untestable and undemoable. Views read the current
/// instant from here rather than calling `Date()`, which also makes every
/// screenshot and unit test deterministic.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct FixedClock: Clock {
    public let now: Date
    public init(now: Date) { self.now = now }
}

public final class SimulatedClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(now: Date) { self.current = now }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }

    /// Days are calendar days, not multiples of 86,400 seconds. On the two
    /// days a year a day is 23 or 25 hours long, the difference is the
    /// difference between "same time tomorrow" and an hour either side of it.
    public func advance(days: Int) {
        lock.lock()
        defer { lock.unlock() }
        current = Calendar.postal.date(byAdding: .day, value: days, to: current) ?? current
    }

    public func advance(hours: Int) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(Double(hours) * 3_600)
    }
}

/// The real one. Used by the shipping app; never by tests or screenshots.
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}
