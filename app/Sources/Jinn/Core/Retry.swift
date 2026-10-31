import Foundation

func retry<T>(_ attempts: Int = 3, base: Double = 0.15, _ body: () async throws -> T) async throws -> T {
    var delay = base
    for i in 1...attempts {
        do { return try await body() }
        catch {
            if i == attempts { throw error }
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            delay *= 2
        }
    }
    fatalError("unreachable")
}

func withTimeout<T: Sendable>(_ seconds: Double, _ what: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            throw JinnError("\(what) timed out after \(Int(seconds))s")
        }
        defer { g.cancelAll() }
        return try await g.next()!
    }
}
