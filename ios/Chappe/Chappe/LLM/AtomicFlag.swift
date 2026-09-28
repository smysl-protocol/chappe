import Foundation

/// Потокобезопасный флаг отмены: выставляется из nonisolated-контекста
/// (cancelActiveGeneration), читается циклом генерации между токенами.
/// NSLock достаточно — обращения редкие.
nonisolated final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        value = false
    }
}
