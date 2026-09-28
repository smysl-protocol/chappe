import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// WP1 (бриф владельца 05.08): смена ключа известного контакта обязана
// подниматься предупреждением, а не приниматься молча — главный признак
// подмены. Гейт — КОДОМ в ContactStore (непреложное №9), UI лишь
// показывает исход. Замок: тест краснеет, если кандидат с именем
// существующего контакта и ДРУГИМ ключом сохраняется без явного
// принятия человеком.
// ============================================================================

@Suite(.serialized)   // общий файл contacts.json — параллельно нельзя
struct KeyChangeGateTests {

    private func withCleanStore(_ body: () throws -> Void) rethrows {
        // свой корень хранилища на вызов (тест-инфра 10.08): гонки
        // общего contacts.json между сюитами исчезают по построению
        try ContactStore.$testStorageRoot.withValue(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("keychange-\(UUID().uuidString)")) {
            try body()
        }
    }

    private func makeContact(name: String, verified: Bool? = nil) -> Contact {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        return Contact(id: Identity.fingerprint(of: key), name: name,
                       publicKeyBase64: key.rawRepresentation
                           .base64EncodedString(),
                       addedAt: Date(), verified: verified)
    }

    @Test("то же имя, другой ключ — НЕ сохраняется молча")
    func sameNameNewKeyIsNotAcceptedSilently() {
        withCleanStore {
            let marina = makeContact(name: "Марина", verified: true)
            ContactStore.upsert(marina)

            let impostor = makeContact(name: "Марина")
            let outcome = ContactStore.upsertGuarded(impostor)

            guard case .keyChangeSuspected(let existing, let candidate)
                    = outcome else {
                Issue.record("смена ключа принята молча: \(outcome)")
                return
            }
            #expect(existing.id == marina.id)
            #expect(candidate.id == impostor.id)
            // ничего не сохранено — проверка АДРЕСНАЯ, не count:
            // contacts.json общий на прогон, параллельная сюита могла
            // добавить своего (гонка добавителей, прогон 10.08)
            let stored = ContactStore.load()
            #expect(stored.first { $0.id == impostor.id } == nil,
                    "самозванец не сохранён")
            #expect(stored.first { $0.id == marina.id }?.verified == true,
                    "прежняя Марина цела")
        }
    }

    @Test("имя сравнивается без регистра и пробелов")
    func nameMatchIsNormalized() {
        withCleanStore {
            ContactStore.upsert(makeContact(name: "Марина"))
            let outcome = ContactStore.upsertGuarded(
                makeContact(name: "  марина "))
            guard case .keyChangeSuspected = outcome else {
                Issue.record("регистр/пробелы обошли гейт: \(outcome)")
                return
            }
        }
    }

    @Test("тот же ключ — прежний путь: обновление без подозрений")
    func sameKeyReimportIsPlainUpdate() {
        withCleanStore {
            let anna = makeContact(name: "Анна", verified: true)
            ContactStore.upsert(anna)
            var renamed = anna
            renamed.name = "Анна Т."
            guard case .saved(let contacts) =
                    ContactStore.upsertGuarded(renamed) else {
                Issue.record("тот же ключ поднял ложное подозрение")
                return
            }
            #expect(contacts.count == 1)
            #expect(contacts[0].name == "Анна Т.")
            #expect(contacts[0].verified == true, "сверка не сбивается")
        }
    }

    @Test("новое имя, новый ключ — добавляется как раньше")
    func freshContactIsSaved() {
        withCleanStore {
            let anna = makeContact(name: "Анна")
            let boris = makeContact(name: "Борис")
            ContactStore.upsert(anna)
            guard case .saved(let contacts) = ContactStore.upsertGuarded(boris)
            else {
                Issue.record("новый контакт завёрнут ложно")
                return
            }
            // адресно, не count: общий contacts.json — параллельная
            // сюита могла добавить своего (гонка добавителей, 10.08)
            #expect(contacts.contains { $0.id == anna.id })
            #expect(contacts.contains { $0.id == boris.id })
        }
    }

    @Test("явное принятие: старый уходит, доверие сброшено, история едет")
    func explicitAcceptReplacesDemotesAndMigrates() {
        withCleanStore {
            let old = makeContact(name: "Марина", verified: true)
            ContactStore.upsert(old)
            // история у старого ключа
            let entry = ChatEntry(kind: .incoming, text: "привет с пирса")
            HumanChatStore.upsertLog(entry, contactID: old.id)
            defer {
                HumanChatStore.saveLog([], contactID: old.id)
            }

            var fresh = makeContact(name: "Марина")
            fresh.verified = nil          // даже «без пометки» не пролезает
            let contacts = ContactStore.acceptKeyChange(oldID: old.id, fresh)
            defer { HumanChatStore.saveLog([], contactID: fresh.id) }

            #expect(contacts.count == 1)
            #expect(contacts[0].id == fresh.id)
            #expect(contacts[0].verified == false,
                    "новый ключ обязан пересверяться")
            #expect(!contacts.contains { $0.id == old.id })
            // история переехала к новому id
            let migrated = HumanChatStore.loadLog(contactID: fresh.id)
            #expect(migrated.contains { $0.text == "привет с пирса" },
                    "история чата обязана переехать к новому ключу")
        }
    }
}
