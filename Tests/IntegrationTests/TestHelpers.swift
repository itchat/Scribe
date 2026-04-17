import Foundation

/// Thread-safe counter for testing.
final class CallCounter: @unchecked Sendable {
    private var _count = 0
    private let lock = NSLock()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
        return _count
    }
}
