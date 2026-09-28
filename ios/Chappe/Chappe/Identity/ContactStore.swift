import Foundation
import CryptoKit

// ============================================================================
// Контакты (веха, фаза 2). Обмен: payload {v, name, pub} → base64 —
// одинаков для QR и буфера обмена. Добавление всегда через
// подтверждение человеком с отпечатком. Хранилище — по правилам
// SafeHistoryDecoder (28.07): битые записи скипаются, файл в карантин.
// ============================================================================

/// Миграции полей — только аддитивные optional (правило хранилищ).
nonisolated struct Contact: Codable, Identifiable, Hashable, Sendable {
    /// ID = отпечаток ключа (8 символов base32).
    var id: String
    var name: String
    var publicKeyBase64: String
    var addedAt: Date
    /// Доверие (импорт из галереи, 30.07.2026):
    /// - false — карточка пришла по непроверенному каналу (изображение
    ///   могло быть подменено по дороге), показываем «непроверен»;
    /// - true — отпечаток сверен голосом или лично; ставится ТОЛЬКО
    ///   после сверки, никогда при импорте;
    /// - nil — старые контакты и скан камерой (до модели доверия),
    ///   без пометки.
    var verified: Bool?

    var publicKey: Curve25519.KeyAgreement.PublicKey? {
        Data(base64Encoded: publicKeyBase64).flatMap {
            try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0)
        }
    }

    var isUnverified: Bool { verified == false }
}

nonisolated enum ContactStore {

    // MARK: Обмен (QR и буфер — один payload)

    struct ExchangePayload: Codable {
        var v: Int
        var name: String
        var pub: String       // base64 raw 32 байта
    }

    /// Схема карточки контакта (30.07.2026): QR несёт
    /// `rm://contact/<base64>` — самоописываемый, чужой сканер не
    /// перепутает его с сайтом. Разбор принимает и голый base64 —
    /// обратная совместимость с уже распечатанными карточками.
    static let scheme = "rm://contact/"

    /// Мой payload для QR/буфера. nil — ключа нет (Keychain недоступен).
    static func myPayloadBase64() -> String? {
        guard let pub = Identity.publicKey() else { return nil }
        let payload = ExchangePayload(
            v: 1, name: Identity.displayName,
            pub: pub.rawRepresentation.base64EncodedString())
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return data.base64EncodedString()
    }

    /// Текст моего QR: со схемой.
    static func myPayloadText() -> String? {
        myPayloadBase64().map { scheme + $0 }
    }

    /// Разбор чужого payload (QR, буфер, изображение) → контакт-кандидат.
    /// Принимает `rm://contact/<base64>` и голый base64 (старые
    /// карточки). Проверки: версия, валидный ключ 32 байта, имя непустое.
    static func parse(_ text: String) -> Contact? {
        var base64 = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if base64.lowercased().hasPrefix(scheme) {
            base64 = String(base64.dropFirst(scheme.count))
        }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(ExchangePayload.self,
                                                      from: data),
              payload.v == 1,
              let keyData = Data(base64Encoded: payload.pub),
              keyData.count == 32,
              !Identity.isTestVectorMaterial(keyData),  // WP4: тест-ключи вне прода
              let key = try? Curve25519.KeyAgreement.PublicKey(
                  rawRepresentation: keyData)
        else { return nil }
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return Contact(id: Identity.fingerprint(of: key), name: name,
                       publicKeyBase64: payload.pub, addedAt: Date())
    }

    // MARK: Хранилище

    /// Инъекция корня хранилища для тестов (тест-инфра, заказ владельца
    /// 10.08): сюита оборачивает свои операции в
    /// `$testStorageRoot.withValue(свой каталог)` и получает СВОЙ
    /// contacts.json. Общий файл кусал трижды (08–10.08): параллельные
    /// сюиты перетирали друг друга целыми списками (lost update), один
    /// раз краш-индекс валил весь тест-хост. В проде всегда nil —
    /// путь прежний.
    @TaskLocal static var testStorageRoot: URL?

    static func url() throws -> URL {
        if let root = testStorageRoot {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            return root.appendingPathComponent("contacts.json")
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("contacts.json")
    }

    static func load() -> [Contact] {
        guard let url = try? url(),
              let data = try? Data(contentsOf: url) else { return [] }
        guard let contacts = SafeHistoryDecoder.decodeArray(
            Contact.self, from: data, label: "contacts") else {
            SafeHistoryDecoder.quarantine(url)
            return []
        }
        return contacts
    }

    static func save(_ contacts: [Contact]) {
        guard let url = try? url() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(contacts).write(to: url, options: .atomic)
    }

    /// Добавить/обновить (по отпечатку). Возвращает актуальный список.
    /// Доверие при повторном импорте: id — это отпечаток ключа, тот же
    /// id = тот же ключ, поэтому сверенный контакт («проверен») своей
    /// отметки НЕ теряет; понизить её импортом нельзя.
    @discardableResult
    static func upsert(_ contact: Contact) -> [Contact] {
        var contacts = load()
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index].name = contact.name
            contacts[index].publicKeyBase64 = contact.publicKeyBase64
            if contacts[index].verified != true {
                contacts[index].verified =
                    contact.verified ?? contacts[index].verified
            }
        } else {
            contacts.append(contact)
        }
        save(contacts)
        return contacts
    }

    // MARK: Гейт смены ключа (WP1, 05.08.2026)

    /// Исход охраняемого импорта: подмена не принимается молча.
    enum ImportOutcome: Equatable {
        case saved([Contact])
        /// Кандидат носит имя существующего контакта, но ДРУГОЙ ключ —
        /// главный признак подмены. Ничего не сохранено; решает человек
        /// явным действием (acceptKeyChange) после громкого
        /// предупреждения в UI.
        case keyChangeSuspected(existing: Contact, candidate: Contact)
    }

    /// Имя для сравнения: регистр и края пробелов не различают людей.
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Охраняемый импорт — гейт КОДОМ, не в UI (непреложное №9):
    /// тот же ключ — обычное обновление; новое имя — добавление;
    /// имя существующего контакта с другим ключом — подозрение на
    /// подмену, ничего не сохраняется.
    @discardableResult
    static func upsertGuarded(_ contact: Contact) -> ImportOutcome {
        let contacts = load()
        if contacts.contains(where: { $0.id == contact.id }) {
            return .saved(upsert(contact))
        }
        if let clash = contacts.first(where: {
            normalizedName($0.name) == normalizedName(contact.name) }) {
            return .keyChangeSuspected(existing: clash, candidate: contact)
        }
        // B2: тревога живёт и после удаления — надгробие помнит
        // последний ключ имени; возврат с ДРУГИМ ключом подозрителен
        if let tomb = ContactAdmission.resurrectionAlarm(candidate: contact) {
            let ghost = Contact(id: tomb.lastID, name: contact.name,
                                publicKeyBase64: "", addedAt: Date())
            return .keyChangeSuspected(existing: ghost, candidate: contact)
        }
        return .saved(upsert(contact))
    }

    /// Явное принятие нового ключа (после предупреждения): старый
    /// контакт уходит, история чата переезжает к новому id, доверие
    /// принудительно сброшено — новый ключ обязан пересверяться.
    @discardableResult
    static func acceptKeyChange(oldID: String, _ contact: Contact) -> [Contact] {
        var fresh = contact
        fresh.verified = false
        HumanChatStore.migrateHistory(from: oldID, to: fresh.id)
        remove(id: oldID)
        return upsert(fresh)
    }

    /// Отметка «проверен» — ТОЛЬКО после сверки отпечатка голосом или
    /// лично (явное действие человека), никогда при импорте.
    static func markVerified(id: String) {
        var contacts = load()
        guard let index = contacts.firstIndex(where: { $0.id == id })
        else { return }
        contacts[index].verified = true
        save(contacts)
    }

    static func remove(id: String) {
        save(load().filter { $0.id != id })
    }
}
