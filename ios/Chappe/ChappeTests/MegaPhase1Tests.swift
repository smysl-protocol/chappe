import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Мега-задача 14.08, фаза 1 — замки по пунктам.
// ============================================================================

nonisolated struct MegaPhase1Tests {

    // МЕГА-1: оба телефона звались «Chappe» — дефолт на имя приложения.
    // Теперь: до ввода — «Без имени»; введённое имя едет в карточке
    // знакомства; код-ID стабилен. Слом: вернуть дефолт AppIdentity.
    // appName в Identity.displayName — оба ожидания краснеют.
    @Test("имя: без ввода — «Без имени», введённое едет в карточке")
    func nameRidesInCardNeverAppName() throws {
        let saved = UserDefaults.standard.string(forKey: "identity_display_name")
        defer { UserDefaults.standard.set(saved, forKey: "identity_display_name") }

        // до ввода: заглушка, НЕ имя приложения
        UserDefaults.standard.removeObject(forKey: "identity_display_name")
        #expect(Identity.displayName == "Без имени", Comment(rawValue:
                "дефолт «Chappe» путал: оба телефона в знакомстве звались "
                + "одинаково — до ввода обязана быть заглушка"))
        #expect(Identity.displayName != AppIdentity.appName)
        #expect(!Identity.hasCustomName)

        // введённое имя едет в карточке знакомства, ID стабилен
        let idBefore = Identity.myFingerprint()
        Identity.displayName = "Али-тест"
        #expect(Identity.hasCustomName)
        let payload = try #require(ContactStore.myPayloadText())
        let card = try #require(ContactStore.parse(payload))
        #expect(card.name == "Али-тест", Comment(rawValue:
                "карточка знакомства обязана нести ВВЕДЁННОЕ имя — "
                + "контакт при знакомстве видит имя, не «Chappe»"))
        #expect(card.id == idBefore, "код-ID под именем не меняется")

        // пробелы-только = не имя
        Identity.displayName = "   "
        #expect(!Identity.hasCustomName)
        #expect(Identity.displayName == "Без имени")
    }

    // МЕГА-3: сообщение в чат без доставки молчало жёлтой отметкой.
    // Ушло, но не подтверждено дольше минуты → пузырь говорит словами.
    // Слом: убрать undeliveredHint из ChatEntry/вью — красный.
    @Test("недоставка дольше минуты — честные слова, не молчание")
    func undeliveredSaysSoAfterMinute() {
        let sent = Date(timeIntervalSince1970: 1_760_000_000)
        var stale = ChatEntry(kind: .outgoing, text: "в пустоту", date: sent)
        stale.sentAt = sent
        #expect(stale.undeliveredHint(now: sent.addingTimeInterval(90))
                == "пока не доставлено — ждём собеседника", Comment(
                rawValue: "ушедшее без подтверждения обязано сказать об "
                + "этом словами — молча терять нельзя (мега-3)"))
        #expect(stale.undeliveredHint(now: sent.addingTimeInterval(30))
                == nil, "первую минуту не паникуем")

        var delivered = stale
        delivered.deliveredAt = sent.addingTimeInterval(10)
        #expect(delivered.undeliveredHint(now: sent.addingTimeInterval(90))
                == nil, "доставленному хинт не положен")

        var queued = ChatEntry(kind: .outgoing, text: "в очереди",
                               date: sent)
        queued.status = "доставлю, когда окажетесь рядом"
        #expect(queued.undeliveredHint(now: sent.addingTimeInterval(90))
                == nil, "не ушедшее покрыто честным статусом очереди")

        let incoming = ChatEntry(kind: .incoming, text: "чужое", date: sent)
        #expect(incoming.undeliveredHint(now: sent.addingTimeInterval(90))
                == nil, "входящих не касается")
    }

}

// ============================================================================
// МЕГА-13 (фаза 5): «Начать заново» обязан КРИПТОГРАФИЧЕСКИ стирать
// ключ из Keychain — не только менять активную личность. Прямой
// Keychain-запрос по счетам ключа/сида после reset() обязан вернуть
// ПУСТО (SecItemDelete удаляет материал на уровне API; шифрование
// item-ключей — SEP). Слом: превратить reset() в смену указателя без
// keychainDelete — красный.
// ============================================================================

nonisolated enum KeychainProbe {
    static func read(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.chappe.app.identity",
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out)
                == errSecSuccess else { return nil }
        return out as? Data
    }
}

nonisolated struct KeychainEraseTests {

    @MainActor
    @Test("сброс личности стирает ключ и сид из Keychain подчистую")
    func resetErasesKeyMaterial() throws {
        let savedSeed = Identity.exportSeedHex()
        defer { if let savedSeed { _ = Identity.restore(fromSeedHex: savedSeed) } }

        let before = try #require(Identity.myFingerprint())
        #expect(KeychainProbe.read(account: "identity-seed-v1") != nil,
                "предусловие: сид лежит в Keychain")

        Identity.reset()
        #expect(KeychainProbe.read(account: "identity-seed-v1") == nil,
                Comment(rawValue: "после сброса СИД обязан отсутствовать "
                + "в Keychain — иначе «начать заново» лишь прячет старую "
                + "личность, а не стирает её (мега-13)"))
        #expect(KeychainProbe.read(account: "curve25519-private") == nil,
                "приватный ключ тоже стёрт")

        // следующий доступ рождает НОВУЮ личность
        let after = try #require(Identity.myFingerprint())
        #expect(after != before, "новая личность, не воскрешение старой")
    }
}

// ============================================================================
// МЕГА-14 (фаза 5): экран радио-настроек НЕ подписан на пульс пакетов.
// eventCounter публикуется на каждый принятый пакет — подписка
// перестраивала весь List каждые ~2 с (глохли тапы, грелась батарея).
// Живой статус обновляет свой TimelineView. Слом: вернуть
// @ObservedObject var delivery в BLECheckView — Mirror увидит обёртку,
// тест красный.
// ============================================================================

nonisolated struct RadioScreenDecouplingTests {

    @MainActor
    @Test("BLECheckView не наблюдает DeliveryManager целиком")
    func radioScreenNotObservingDelivery() {
        let mirror = Mirror(reflecting: BLECheckView())
        let observed = mirror.children.contains { child in
            String(describing: type(of: child.value))
                .contains("ObservedObject<DeliveryManager>")
        }
        #expect(!observed, Comment(rawValue:
                "подписка на DeliveryManager = перестройка экрана на "
                + "каждый пакет — тапы глохнут, батарея греется (мега-14); "
                + "живой статус держит TimelineView"))
    }
}

// ============================================================================
// Регресс билда 24 (поле 14.08): «Начать заново» НЕ стирал отображаемое
// имя (identity_display_name — новое поле мега-1) и флаг «вопрос имени
// задан» — после сброса оставались те же имена, повторное знакомство
// шло по старому мусору. Перекрёст «имя × сброс», которого не было:
// прошлая жизнь (имя + контакт + seq пары + сироты) → freshStart →
// НОЛЬ следов. Ожидания — литералы ключей, посчитанные руками извне.
// Слом: убрать из freshStart стирание имени / флага / сироту-свип —
// соответствующее ожидание краснеет.
// ============================================================================

nonisolated struct FreshStartCrossTests {

    @MainActor
    @Test("имя × сброс: после «Начать заново» ноль следов, включая имя")
    func freshStartLeavesNoTraceIncludingName() throws {
        let ud = UserDefaults.standard
        let fm = FileManager.default

        // --- снапшот всего разрушаемого (вернём в defer) ---
        let savedSeed = Identity.exportSeedHex()
        let savedName = ud.string(forKey: "identity_display_name")
        let savedPrompted = ud.object(forKey: "identity.name.prompted")
        let savedContacts = ContactStore.load()
        // путь каталога чатов — руками (ApplicationSupport/Chats),
        // внешнее ожидание: сброс обязан снести именно его
        let chatsDir = try fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true)
            .appendingPathComponent("Chats", isDirectory: true)
        let chatsBackup = fm.temporaryDirectory
            .appendingPathComponent("chats-backup-\(UUID().uuidString)")
        if fm.fileExists(atPath: chatsDir.path) {
            try? fm.copyItem(at: chatsDir, to: chatsBackup)
        }
        defer {
            if let savedSeed { _ = Identity.restore(fromSeedHex: savedSeed) }
            if let savedName { ud.set(savedName, forKey: "identity_display_name") }
            if let savedPrompted {
                ud.set(savedPrompted, forKey: "identity.name.prompted")
            }
            ContactStore.save(savedContacts)
            if fm.fileExists(atPath: chatsBackup.path) {
                try? fm.removeItem(at: chatsDir)
                try? fm.copyItem(at: chatsBackup, to: chatsDir)
                try? fm.removeItem(at: chatsBackup)
            }
        }

        let savedGrants = ShareGrantStore.load()
        defer { ShareGrantStore.save(savedGrants) }

        // --- прошлая жизнь ---
        Identity.displayName = "Тест-Сброс"
        ud.set(true, forKey: "identity.name.prompted")
        let peer = Curve25519.KeyAgreement.PrivateKey()
        let contact = Contact(
            id: Identity.fingerprint(of: peer.publicKey),
            name: "Житель прошлой жизни",
            publicKeyBase64: peer.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: Date())
        _ = ContactStore.upsert(contact)
        _ = SeqStore.next(contactID: contact.id)     // seq пары в Keychain
        PeerCaps.markRevB(contactID: contact.id)
        // сироты: контакт давно удалён, а счётчик/способности остались
        _ = SeqStore.next(contactID: "СИРОТА99")
        PeerCaps.markRevB(contactID: "СИРОТА99")
        // живой грант шеринга гео — «отслеживать» включено
        ShareGrantStore.save([ShareGrant(contactID: contact.id,
                                         precision: .exact,
                                         grantedAt: Date(),
                                         ttlSeconds: 3600)])

        // --- сброс ---
        AppReset.freshStart()

        // --- ноль следов ---
        #expect(ud.string(forKey: "identity_display_name") == nil,
                Comment(rawValue: "ИМЯ пережило сброс — регресс билда 24: "
                + "«начать заново» обязан стирать и отображаемое имя"))
        #expect(!Identity.hasCustomName)
        #expect(ud.object(forKey: "identity.name.prompted") == nil,
                "вопрос имени обязан прозвучать заново у новой личности")
        #expect(ContactStore.load().isEmpty, "контактов нет")
        #expect(KeychainProbe.read(account: "identity-seed-v1") == nil)
        #expect(KeychainProbe.read(account: "pair-seq.\(contact.id)") == nil,
                "seq пары контакта стёрт")
        #expect(KeychainProbe.read(account: "pair-seq.СИРОТА99") == nil,
                Comment(rawValue: "сирота-счётчик (контакт давно удалён) "
                + "обязан умереть при полном сбросе — иначе новая жизнь "
                + "наследует чужой seq"))
        #expect(ud.object(forKey: "peercaps.\(contact.id)") == nil)
        #expect(ud.object(forKey: "peercaps.СИРОТА99") == nil,
                "сироты-способности стёрты")
        #expect(Outbox.loadQueueRaw().isEmpty, "очередь недоставленного пуста")
        #expect(ShareGrantStore.load().isEmpty, Comment(rawValue:
                "гранты шеринга гео обязаны умереть со сбросом — иначе "
                + "у стёртой личности продолжает висеть значок геолокации "
                + "(поле 14.08)"))
        // сам каталог может быть пересоздан пустым любым чтением —
        // след это ФАЙЛЫ в нём, их быть не должно
        let leftovers = (try? fm.contentsOfDirectory(atPath: chatsDir.path)) ?? []
        #expect(leftovers.isEmpty, "файлов переписки после сброса нет")
    }
}
