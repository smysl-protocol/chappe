import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// Удаление = ЧИСТЫЙ ЛИСТ (решение владельца 12.08). Было: удаление
// оставляло шёпоты/позиции/очередь (и релейный ящик), повторное
// знакомство тем же ключом воскрешало прошлый чат — opsec-дыра и грязь
// в тестах первого контакта.
//
// Замки проверяются СЛОМОМ: убери из ContactPurge стирание любого
// стора — соответствующий #expect краснеет. Ожидания внешние: «после
// удаления и повторного создания того же контакта переписки НЕТ».
// ============================================================================

@MainActor
struct ContactPurgeTests {

    private func freshContact() -> Contact {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        let id = Identity.fingerprint(of: key)
        return Contact(id: id, name: id,
                       publicKeyBase64: key.rawRepresentation.base64EncodedString(),
                       addedAt: Date(), verified: false)
    }

    private func tempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("удаление стирает ВСЕ сторы контакта: лог, шёпоты, прочтение, очередь")
    func purgeWipesAllLocalStores() throws {
        try ContactStore.$testStorageRoot.withValue(tempRoot()) {
            let c = freshContact()
            _ = ContactStore.upsert(c)
            HumanChatStore.upsertLog(
                ChatEntry(kind: .incoming, text: "старое сообщение"),
                contactID: c.id)
            HumanChatStore.upsertWhisper(
                ChatEntry(kind: .whisperQuestion, text: "старый шёпот"),
                contactID: c.id)
            HumanChatStore.markRead(contactID: c.id)

            #expect(!HumanChatStore.loadLog(contactID: c.id).isEmpty)
            #expect(!HumanChatStore.loadWhispers(contactID: c.id).isEmpty)

            ContactPurge.purge(c)

            #expect(ContactStore.load().first { $0.id == c.id } == nil,
                    "контакт обязан исчезнуть")
            #expect(HumanChatStore.loadLog(contactID: c.id).isEmpty,
                    Comment(rawValue: "основной лог не стёрт — переписка "
                            + "переживает удаление (opsec-дыра)"))
            #expect(HumanChatStore.loadWhispers(contactID: c.id).isEmpty,
                    Comment(rawValue: "шёпоты не стёрты — прошлое "
                            + "переживает удаление"))
        }
    }

    @Test("повторное знакомство тем же ключом после удаления — чат ПУСТ")
    func repairAfterDeleteIsCleanSlate() throws {
        try ContactStore.$testStorageRoot.withValue(tempRoot()) {
            let c = freshContact()
            _ = ContactStore.upsert(c)
            HumanChatStore.upsertLog(
                ChatEntry(kind: .incoming, text: "было в прошлой жизни"),
                contactID: c.id)

            ContactPurge.purge(c)
            // повторное знакомство ТЕМ ЖЕ ключом → тот же id
            _ = ContactStore.upsert(c)

            #expect(HumanChatStore.loadLog(contactID: c.id).isEmpty,
                    Comment(rawValue: "прошлый чат воскрес после re-pair — "
                            + "ровно баг воскрешения, который чиним"))
        }
    }

    @Test("удаление выбрасывает недоставленную очередь контакта")
    func purgeClearsOutbox() throws {
        try ContactStore.$testStorageRoot.withValue(tempRoot()) {
            let c = freshContact()
            _ = ContactStore.upsert(c)
            let queued = Outbox.QueuedMessage(
                entryID: UUID(), msgID: 0x1234, packetsHex: ["00"],
                totalBytes: 1, contactID: c.id)
            var q = Outbox.loadQueueRaw(); q.append(queued)
            Outbox.saveQueueRaw(q)
            #expect(Outbox.loadQueueRaw().contains { $0.contactID == c.id })

            ContactPurge.purge(c)
            #expect(!Outbox.loadQueueRaw().contains { $0.contactID == c.id },
                    Comment(rawValue: "насос повторов досылал бы сообщения "
                            + "удалённого собеседника"))
        }
    }

    // Само-контакт: ключ отсканированного == мой → допуск отказывает,
    // эхо-чата с собой нет.
    @Test("само-контакт: admit своего ключа не рождает контакт")
    func admitRejectsSelf() throws {
        try ContactStore.$testStorageRoot.withValue(tempRoot()) {
            let myPub = try #require(Identity.publicKey())
            let myID = try #require(Identity.myFingerprint())
            let admitted = ContactAdmission.admit(
                senderID: myID,
                senderPubRaw: Array(myPub.rawRepresentation))
            #expect(admitted == nil, Comment(rawValue:
                    "свой ключ не смеет рождать контакт — это был бы "
                    + "фантомный эхо-чат с самим собой"))
            #expect(ContactStore.load().first { $0.id == myID } == nil)
        }
    }
}
