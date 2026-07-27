import Foundation

/// Serializes snapshot work per on-disk repository root. Repositories created
/// separately for the same path share a coordinator, so a reload is also a
/// durability barrier for writes queued by an older store instance.
final class RepositoryIOCoordinator: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: RepositoryIOCoordinator] = [:]

    static func shared(scope: String, rootURL: URL) -> RepositoryIOCoordinator {
        let key = scope + "|" + rootURL.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let coordinator = RepositoryIOCoordinator(label: "app.hedgememo.io.\(scope)")
        registry[key] = coordinator
        return coordinator
    }

    private let queue: DispatchQueue

    private init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func async(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }

    func sync<T>(_ operation: () throws -> T) rethrows -> T {
        try queue.sync(execute: operation)
    }

    func flush() {
        queue.sync {}
    }
}
