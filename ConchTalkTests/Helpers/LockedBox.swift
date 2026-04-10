import Foundation

/// 线程安全的测试状态容器，供同步回调跨并发域写入。
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    nonisolated func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    nonisolated func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    nonisolated var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
