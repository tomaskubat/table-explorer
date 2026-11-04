import Foundation

/// A query may finish while a separate connection is issuing KILL QUERY.
/// Hold this gate until the kill returns, so the original session cannot start
/// a different statement under the same MariaDB thread ID in between.
final class QueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var interrupt: (() throws -> Void)?

    var wasRequested: Bool { lock.withLock { requested } }

    func perform<T>(interrupt: @escaping () throws -> Void, operation: () throws -> T) throws -> T {
        try lock.withLock {
            if requested { throw CancellationError() }
            self.interrupt = interrupt
        }
        defer { lock.withLock { self.interrupt = nil } }
        return try operation()
    }

    func stop() throws {
        try lock.withLock {
            requested = true
            try interrupt?()
        }
    }
}
