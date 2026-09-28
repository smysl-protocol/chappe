import Foundation
import CryptoKit

// ============================================================================
// Identity — личность узла (веха «первое настоящее сообщение», фаза 1).
//
// Пара ключей Curve25519 (X25519). Приватный ключ живёт ТОЛЬКО в
// Keychain устройства: kSecAttrAccessibleAfterFirstUnlock, БЕЗ
// iCloud-синхронизации (kSecAttrSynchronizable не ставится). Профиль
// «как тебя видят» = display name + публичный ключ; ID узла — короткий
// отпечаток ключа (8 символов base32 от SHA-256 публичного ключа).
// ============================================================================

nonisolated enum Identity {

    // Смена bundle ID (30.07.2026) в любом случае отрезает доступ к старым
    // записям Keychain (access group привязан к App ID), поэтому сервис
    // переименован без миграции: ключ идентичности пересоздастся, контакты
    // на dev-телефонах обмениваются QR заново.
    private static let keychainService = "com.chappe.app.identity"
    private static let keychainAccount = "curve25519-private"
    /// Сид личности (ADR 007, решение 02.08): ОТДЕЛЬНЫЙ от кошелькового,
    /// 32 Б; X25519 выводится из него HKDF. Бэкап сида на бумаге
    /// восстанавливает личность офлайн на новом устройстве.
    private static let seedAccount = "identity-seed-v1"
    private static let nameKey = "identity_display_name"

    // MARK: Ключи

    /// Приватный ключ. Порядок: 1) старый «сырой» ключ из Keychain
    /// (установки до сида — не трогаем, у них бэкапа сида нет);
    /// 2) вывод из сида; 3) первого запуска — создаётся СИД, ключ
    /// выводится. Ошибка Keychain — nil (UI честно скажет).
    static func privateKey() -> Curve25519.KeyAgreement.PrivateKey? {
        if let data = keychainRead(account: keychainAccount) {
            hardenAccessibility(account: keychainAccount)   // WP3: миграция
            return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        if let seed = keychainRead(account: seedAccount) {
            hardenAccessibility(account: seedAccount)       // WP3: миграция
            return derived(from: seed)
        }
        var fresh = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &fresh) == errSecSuccess,
              keychainWrite(Data(fresh), account: seedAccount) else { return nil }
        return derived(from: Data(fresh))
    }

    /// Детерминированный вывод X25519 из сида (одинаков на любом
    /// устройстве — основа офлайн-восстановления).
    static func derived(from seed: Data) -> Curve25519.KeyAgreement.PrivateKey? {
        let raw = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: seed),
            salt: Data("Chappe-identity".utf8),
            info: Data("x25519-v1".utf8), outputByteCount: 32)
        return raw.withUnsafeBytes {
            try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data($0))
        }
    }

    /// Сид для бэкапа (hex, 64 символа). nil — личность старого образца
    /// («сырой» ключ без сида): для неё бэкап сида невозможен, честно.
    static func exportSeedHex() -> String? {
        guard keychainRead(account: keychainAccount) == nil,
              let seed = keychainRead(account: seedAccount) else { return nil }
        return seed.map { String(format: "%02x", $0) }.joined()
    }

    /// Восстановление с бумаги: сид → та же личность. Оффлайн.
    /// Затирает текущую личность устройства — вызывать только по
    /// явному действию пользователя.
    @discardableResult
    static func restore(fromSeedHex hex: String) -> Bool {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 64 else { return false }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard next <= clean.endIndex,
                  let byte = UInt8(clean[index..<next], radix: 16)
            else { return false }
            bytes.append(byte)
            index = next
        }
        guard !isTestVectorMaterial(Data(bytes)),     // WP4: не тест-вектор
              derived(from: Data(bytes)) != nil,
              keychainWrite(Data(bytes), account: seedAccount) else {
            return false
        }
        keychainDelete(account: keychainAccount)   // старый сырой ключ
        return true
    }

    static func publicKey() -> Curve25519.KeyAgreement.PublicKey? {
        privateKey()?.publicKey
    }

    /// Полный сброс личности («начать заново», 12.08): удаляет ключ и
    /// сид из Keychain. КРИТИЧНО: Keychain ПЕРЕЖИВАЕТ удаление
    /// приложения (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly не
    /// стирается при деинсталляции), поэтому переустановка из
    /// TestFlight личность НЕ меняет — та же личность даёт те же
    /// релейные ящики, и старый чат «воскресает» (друг досылает / релей
    /// переотдаёт). Сброс нужен ЯВНОЙ кнопкой. Следующий доступ
    /// сгенерирует новую личность: новый отпечаток, новые ящики —
    /// старые сообщения на релее становятся недостижимы.
    /// Флаг «вопрос имени уже задавали» (стартовый алерт ContentView).
    /// Живёт здесь: судьба флага — судьба личности.
    static let namePromptedKey = "identity.name.prompted"

    static func reset() {
        keychainDelete(account: keychainAccount)
        keychainDelete(account: seedAccount)
        // Имя и флаг вопроса — часть личности (регресс билда 24: после
        // «начать заново» оставались старые имена, а вопрос имени у
        // новой личности не задавался вовсе)
        UserDefaults.standard.removeObject(forKey: nameKey)
        UserDefaults.standard.removeObject(forKey: namePromptedKey)
    }

    // MARK: Гейт тестовых ключей (WP4, 05.08.2026)

    /// Тестовые вектора и вырожденный материал в проде запрещены —
    /// замком, не комментарием (TestKeyGuardTests). Ловятся шаблоны
    /// кросс-векторов (лесенка ±1, повтор 16-байтового куска — 01..20 и
    /// a0..af ×2 из RelayClientTests) и «все байты равны». Настоящий
    /// ключ/сид — SecRandom, вероятность ложного срабатывания ничтожна.
    static func isTestVectorMaterial(_ raw: Data) -> Bool {
        guard raw.count == 32 else { return true }
        let bytes = Array(raw)
        if bytes.allSatisfy({ $0 == bytes[0] }) { return true }
        let up = (1..<32).allSatisfy {
            bytes[$0] == bytes[$0 - 1] &+ 1
        }
        let down = (1..<32).allSatisfy {
            bytes[$0] == bytes[$0 - 1] &- 1
        }
        if up || down { return true }
        if Array(bytes[0..<16]) == Array(bytes[16..<32]) { return true }
        return false
    }

    // MARK: Профиль

    /// Человек ввёл своё имя? До ввода показывается «Без имени» —
    /// имя приложения дефолтом НЕ используется (мега-1, 14.08: оба
    /// телефона звались «Chappe», в знакомстве не различить).
    static var hasCustomName: Bool {
        !((UserDefaults.standard.string(forKey: nameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Заглушка до ввода имени.
    static let unnamedPlaceholder = "Без имени"

    static var displayName: String {
        get {
            let stored = (UserDefaults.standard.string(forKey: nameKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? Self.unnamedPlaceholder : stored
        }
        set {
            UserDefaults.standard.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: nameKey)
        }
    }

    /// ID узла: 8 символов base32 от SHA-256 публичного ключа.
    static func fingerprint(of publicKey: Curve25519.KeyAgreement.PublicKey)
    -> String {
        let digest = SHA256.hash(data: publicKey.rawRepresentation)
        return base32(Array(digest.prefix(5)))   // 5 байт → 8 символов
    }

    static func myFingerprint() -> String? {
        publicKey().map(fingerprint(of:))
    }

    /// base32 без паддинга (RFC 4648, верхний регистр) — читается вслух.
    static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, acc = 0
        var out = ""
        for byte in bytes {
            acc = (acc << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(acc >> bits) & 31])
            }
        }
        if bits > 0 {
            out.append(alphabet[(acc << (5 - bits)) & 31])
        }
        return out
    }

    // MARK: Keychain (без iCloud: kSecAttrSynchronizable не задаётся)

    private static func keychainRead(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
        else { return nil }
        return out as? Data
    }

    private static func keychainWrite(_ data: Data, account: String) -> Bool {
        // WP3 (05.08): ThisDeviceOnly — ключ и сид НЕ мигрируют в
        // резервные копии (iCloud и локальные). Явный путь переноса
        // личности — бумажный сид; других не задумано. AfterFirstUnlock
        // остаётся: BLE-приём работает в фоне при заблокированном экране.
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: account,
            ]
            return SecItemUpdate(query as CFDictionary,
                                 [kSecValueData: data,
                                  kSecAttrAccessible:
                                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
                                 as CFDictionary)
                == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Миграция записей, созданных до WP3 (AfterFirstUnlock без
    /// ThisDeviceOnly): атрибут доступности подтягивается на чтении.
    /// Идемпотентно; ошибка не мешает работе (следующий запуск повторит).
    private static func hardenAccessibility(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
        ]
        SecItemUpdate(query as CFDictionary,
                      [kSecAttrAccessible:
                        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
                      as CFDictionary)
    }

    private static func keychainDelete(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
