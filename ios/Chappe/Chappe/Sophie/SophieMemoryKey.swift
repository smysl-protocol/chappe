import Foundation
import CryptoKit
import Security

// ============================================================================
// Ключ шифрования памяти Софи (шаг 3 линии Софи, решение владельца 21.08).
//
// Память шифруется КЛЮЧОМ, не только file protection: ключ в Keychain
// устройства, «Начать заново» = уничтожение ключа = КРИПТОСТИРАНИЕ
// (сильнее и чище построчного удаления). Keychain переживает снос
// приложения — поэтому ключ рубится именно сбросом (SophiePurge), а не
// удалением приложения.
//
// Паттерн Keychain — как у Identity: generic password, свой service,
// ThisDeviceOnly (не мигрирует в бэкапы), AfterFirstUnlock (фоновая
// консолидация P3 работает при заблокированном экране).
// ============================================================================

nonisolated enum SophieMemoryKey {

    static let service = "chappe.sophie.memory"
    static let account = "memory_key"

    /// Ключ есть? Вернуть; нет — создать и вернуть. nil — Keychain отказал.
    static func ensure() -> SymmetricKey? {
        if let existing = load() { return existing }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        return write(data) ? fresh : nil
    }

    /// Только существующий ключ; nil — ключа нет (память нечитаема).
    static func load() -> SymmetricKey? {
        guard let data = read(), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Криптостирание: без ключа шифрованный файл памяти — шум.
    static func destroy() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Для тестов (сохранить/вернуть боевой ключ вокруг прогона)

    static func rawData() -> Data? { read() }

    @discardableResult
    static func restoreRaw(_ data: Data) -> Bool { write(data) }

    // MARK: Keychain (идиомы Identity: без iCloud-синка, ThisDeviceOnly)

    private static func read() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
        else { return nil }
        return out as? Data
    }

    private static func write(_ data: Data) -> Bool {
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            return SecItemUpdate(query as CFDictionary,
                                 [kSecValueData: data] as CFDictionary)
                == errSecSuccess
        }
        return status == errSecSuccess
    }
}
