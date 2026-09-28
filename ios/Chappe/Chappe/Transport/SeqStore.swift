import Foundation
import Security

// ============================================================================
// SeqStore — монотонные счётчики пары «я → контакт» (шов рев B, подпись
// транспортной сессии 11.08, п.2 протокола ревью владельца).
//
// seq присваивается сообщению вместе с msgID и НЕ перештамповывается
// (повтор, смена транспорта, ре-ключ, новая эпоха). Живёт ВНЕ рэтчета:
// потеря сессии seq не сбрасывает. Хранение — тот же Keychain-стор, что
// ключ идентичности (сервис com.chappe.app.identity,
// AfterFirstUnlockThisDeviceOnly): счётчик разделяет судьбу ключа.
//
// Здесь же — приёмные отметки (не крипто, UserDefaults): максимальный
// видённый seq контакта (детект сброса отсчёта) и seq последней принятой
// позиции (реплей-защита кодека 7: старая точка не переигрывает свежую).
// ============================================================================

nonisolated enum SeqStore {

    /// Тот же сервис, что у ключа идентичности — по подписи шва.
    static let keychainService = "com.chappe.app.identity"
    private static let accountPrefix = "pair-seq."

    /// Резкий провал seq, за которым приёмник считает отсчёт сброшенным
    /// (переустановка у отправителя) и откатывается к порядку прихода.
    static let resetGapThreshold: UInt32 = 1000

    // MARK: Отправка — монотонный счётчик в Keychain

    /// Следующий seq пары (начинается с 1), с немедленной записью.
    static func next(contactID: String) -> UInt32 {
        let current = readCounter(contactID: contactID)
        let next = current &+ 1
        writeCounter(next, contactID: contactID)
        return next
    }

    /// Последний выданный seq (0 — ещё не слали).
    static func lastIssued(contactID: String) -> UInt32 {
        readCounter(contactID: contactID)
    }

    /// Удаление контакта = чистый лист и для счётчика.
    static func purge(contactID: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: accountPrefix + contactID,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: seenKey(contactID))
        UserDefaults.standard.removeObject(forKey: posKey(contactID))
    }

    /// Полный сброс (начать заново): ВСЕ счётчики пар и приёмные
    /// отметки, включая сирот от давно удалённых контактов — иначе
    /// новая жизнь наследует чужие seq (регресс билда 24).
    static func purgeAll() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let items = out as? [[CFString: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount] as? String,
                      account.hasPrefix(accountPrefix) else { continue }
                let del: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: keychainService,
                    kSecAttrAccount: account,
                ]
                SecItemDelete(del as CFDictionary)
            }
        }
        let ud = UserDefaults.standard
        for key in ud.dictionaryRepresentation().keys
        where key.hasPrefix("seq.seen.") || key.hasPrefix("seq.pos.") {
            ud.removeObject(forKey: key)
        }
    }

    // MARK: Приём — отметки порядка (не крипто)

    private static func seenKey(_ id: String) -> String { "seq.seen.\(id)" }
    private static func posKey(_ id: String) -> String { "seq.pos.\(id)" }

    /// Максимальный видённый seq контакта; вердикт для ленты:
    /// .ordered — seq растёт (порядок держит seq);
    /// .stale — меньше видённого, но в пределах окна (запоздавший кадр);
    /// .resetDetected — резкий провал: отсчёт сброшен (переустановка),
    ///   лента честно откатывается к порядку прихода.
    enum SeqVerdict: Equatable { case ordered, stale, resetDetected }

    static func noteIncoming(contactID: String, seq: UInt32) -> SeqVerdict {
        let key = seenKey(contactID)
        let seen = UInt32(clamping: UserDefaults.standard.integer(forKey: key))
        if seq >= seen {
            UserDefaults.standard.set(Int(seq), forKey: key)
            return .ordered
        }
        if seen &- seq >= resetGapThreshold {
            // отсчёт сброшен: новая точка отсчёта — пришедший seq
            UserDefaults.standard.set(Int(seq), forKey: key)
            return .resetDetected
        }
        return .stale
    }

    /// Позиции (кодек 7): позиция с seq НЕ БОЛЬШЕ уже принятой
    /// отбрасывается — релей не переиграет устаревшую точку (шов №4).
    /// true — позиция свежая, принята и отмечена.
    static func acceptPosition(contactID: String, seq: UInt32) -> Bool {
        let key = posKey(contactID)
        let last = UInt32(clamping: UserDefaults.standard.integer(forKey: key))
        // сброс отсчёта отправителя (переустановка) — принять заново
        if seq <= last, last &- seq < resetGapThreshold { return false }
        UserDefaults.standard.set(Int(seq), forKey: key)
        return true
    }

    // MARK: Keychain-механика (по образцу Identity, тот же сервис)

    private static func readCounter(contactID: String) -> UInt32 {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: accountPrefix + contactID,
            kSecReturnData: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count >= 4 else { return 0 }
        return UInt32(data[0]) | UInt32(data[1]) << 8
            | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
    }

    private static func writeCounter(_ value: UInt32, contactID: String) {
        let data = Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                         UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: accountPrefix + contactID,
            kSecAttrAccessible:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: accountPrefix + contactID,
            ]
            SecItemUpdate(query as CFDictionary,
                          [kSecValueData: data] as CFDictionary)
        }
    }
}

// ============================================================================
// PeerCaps — что доказал собеседник (правило подписи п.5): отправка
// 5/6 только после его кадра 5/6. «revB» ставит любой открывшийся кадр
// 5 или 6; «session2» — только session2-кадр (он один доказывает эпоху).
// Не крипто-материал — UserDefaults.
// ============================================================================

nonisolated enum PeerCaps {

    private static func key(_ id: String) -> String { "peercaps.\(id)" }

    struct Caps: Equatable {
        var revB = false
        var session2 = false
    }

    static func load(contactID: String) -> Caps {
        let raw = UserDefaults.standard.dictionary(forKey: key(contactID))
        return Caps(revB: raw?["revB"] as? Bool ?? false,
                    session2: raw?["session2"] as? Bool ?? false)
    }

    static func markRevB(contactID: String) {
        var caps = load(contactID: contactID)
        caps.revB = true
        save(caps, contactID: contactID)
    }

    static func markSession2(contactID: String) {
        var caps = load(contactID: contactID)
        caps.revB = true
        caps.session2 = true
        save(caps, contactID: contactID)
    }

    static func purge(contactID: String) {
        UserDefaults.standard.removeObject(forKey: key(contactID))
    }

    /// Полный сброс (начать заново): способности всех пиров, включая
    /// сирот от давно удалённых контактов.
    static func purgeAll() {
        let ud = UserDefaults.standard
        for key in ud.dictionaryRepresentation().keys
        where key.hasPrefix("peercaps.") {
            ud.removeObject(forKey: key)
        }
    }

    private static func save(_ caps: Caps, contactID: String) {
        UserDefaults.standard.set(["revB": caps.revB,
                                   "session2": caps.session2],
                                  forKey: key(contactID))
    }
}
