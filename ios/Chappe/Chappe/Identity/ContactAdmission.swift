import Foundation
import CryptoKit

// ============================================================================
// Допуск контактов (B2, спека владельца 09.08).
//
// 1. Скан QR → сразу рабочий чат, встречный скан НЕ обязателен:
//    первое входящее v2 несёт ключ отправителя — неизвестный ключ
//    рождает контакт АВТОМАТИЧЕСКИ (непроверен, имя-заглушка из
//    отпечатка; человеческое имя приедет карточкой знакомства или
//    руками). Галочка сверки — отдельный опциональный индикатор,
//    ставится только внесетевой сверкой, «не сверен» — не запрет.
// 2. Блок ПОМНИТ КЛЮЧ: входящее от заблокированного ключа не рождает
//    ни контакта, ни записи в ленте.
// 3. Удаление оставляет надгробие (имя → последний ключ): возврат с
//    ДРУГИМ ключом под тем же именем обязан поднять тревогу «ключ
//    сменился» — даже когда контакт давно удалён.
// ============================================================================

nonisolated enum ContactAdmission {

    private static let blockedKey = "contacts.blocked.ids"
    private static let tombstonesKey = "contacts.tombstones.v1"

    // MARK: Блок — по ключу, не по имени

    static func blockedIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: blockedKey) ?? [])
    }

    static func isBlocked(id: String) -> Bool {
        blockedIDs().contains(id)
    }

    static func block(id: String) {
        var all = blockedIDs()
        all.insert(id)
        UserDefaults.standard.set(Array(all), forKey: blockedKey)
    }

    static func unblock(id: String) {
        var all = blockedIDs()
        all.remove(id)
        UserDefaults.standard.set(Array(all), forKey: blockedKey)
    }

    /// Стереть надгробия и блоки — «начать заново» (AppReset, 12.08).
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: blockedKey)
        UserDefaults.standard.removeObject(forKey: tombstonesKey)
    }

    // MARK: Надгробия удалённых

    struct Tombstone: Codable, Equatable {
        var lastID: String     // последний известный ключ этого имени
        var blocked: Bool      // «удалить и заблокировать»
    }

    static func tombstones() -> [String: Tombstone] {
        guard let data = UserDefaults.standard.data(forKey: tombstonesKey),
              let dict = try? JSONDecoder().decode(
                [String: Tombstone].self, from: data) else { return [:] }
        return dict
    }

    static func tombstone(forName name: String) -> Tombstone? {
        tombstones()[ContactStore.normalizedName(name)]
    }

    /// Оставить надгробие при удалении контакта.
    static func leaveTombstone(name: String, id: String, blocked: Bool) {
        var all = tombstones()
        all[ContactStore.normalizedName(name)] = Tombstone(lastID: id,
                                                           blocked: blocked)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: tombstonesKey)
        }
    }

    /// Тревога после смерти: имя с надгробия вернулось с ДРУГИМ ключом.
    static func resurrectionAlarm(candidate: Contact) -> Tombstone? {
        guard let tomb = tombstone(forName: candidate.name),
              tomb.lastID != candidate.id else { return nil }
        return tomb
    }

    // MARK: Автодопуск с первого сообщения

    /// Неизвестный отправитель с валидным ключом → контакт-заглушка
    /// (непроверен, имя = отпечаток). nil — ключ заблокирован, входящее
    /// гасится. Известный — просто его id.
    @discardableResult
    static func admit(senderID: String, senderPubRaw: [UInt8]) -> String? {
        // Само-контакт (12.08): ключ отправителя == мой — контакт не
        // рождается, эхо-чата нет. Иначе своя же карточка/эхо-кадр
        // создавали фантомный «непроверенный» чат с самим собой.
        if senderID == Identity.myFingerprint() { return nil }
        guard !isBlocked(id: senderID) else { return nil }
        if ContactStore.load().contains(where: { $0.id == senderID }) {
            return senderID
        }
        guard senderPubRaw.count == 32,
              let key = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: Data(senderPubRaw)),
              Identity.fingerprint(of: key) == senderID else { return nil }
        let contact = Contact(id: senderID, name: senderID,
                              publicKeyBase64: Data(senderPubRaw)
                                  .base64EncodedString(),
                              addedAt: Date(), verified: false)
        // мимо гейта имён НАМЕРЕННО: имя-заглушка = отпечаток, с
        // человеческими именами не сталкивается; гейт живёт на пути
        // карточек (QR/баннер), где имена настоящие
        ContactStore.upsert(contact)
        TransportDiary.note("[допуск] новый собеседник с первого "
                            + "сообщения: \(senderID)")
        return senderID
    }
}
