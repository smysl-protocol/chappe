import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Замки B2 (спека владельца 09.08): контакт с первого сообщения, блок
// по ключу, надгробия удалённых. Сюита .serialized: общие contacts.json
// и UserDefaults блоков/надгробий.
// ============================================================================

@Suite(.serialized)
struct ContactAdmissionTests {

    private func freshKey() -> (id: String, raw: [UInt8]) {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        return (Identity.fingerprint(of: key), Array(key.rawRepresentation))
    }

    @Test("первое сообщение незнакомца рождает непроверенный контакт")
    func admissionCreatesUnverifiedContact() {
        let (id, raw) = freshKey()
        defer { ContactStore.remove(id: id); ContactAdmission.unblock(id: id) }

        #expect(ContactAdmission.admit(senderID: id, senderPubRaw: raw) == id)
        let saved = ContactStore.load().first { $0.id == id }
        #expect(saved != nil, Comment(rawValue:
                "встречный скан не обязателен: неизвестный ключ обязан "
                + "родить контакт (B2)"))
        #expect(saved?.verified == false, "с первого сообщения — непроверен")
        #expect(saved?.name == id, "имя-заглушка = отпечаток, до карточки")
        // повторный допуск того же ключа — тот же id, без дублей
        #expect(ContactAdmission.admit(senderID: id, senderPubRaw: raw) == id)
        #expect(ContactStore.load().filter { $0.id == id }.count == 1)
    }

    @Test("подделка: ключ не сходится с заявленным отпечатком — отказ")
    func admissionRejectsMismatchedKey() {
        let (id, _) = freshKey()
        let (_, otherRaw) = freshKey()
        defer { ContactStore.remove(id: id) }
        #expect(ContactAdmission.admit(senderID: id,
                                       senderPubRaw: otherRaw) == nil)
        #expect(ContactStore.load().first { $0.id == id } == nil)
    }

    @Test("блок помнит ключ: допуска нет, контакт не рождается")
    func blockedKeyIsSilent() {
        let (id, raw) = freshKey()
        ContactAdmission.block(id: id)
        defer { ContactAdmission.unblock(id: id); ContactStore.remove(id: id) }

        #expect(ContactAdmission.admit(senderID: id, senderPubRaw: raw)
                == nil, Comment(rawValue:
                "заблокированный ключ не смеет рождать контакт (B2)"))
        #expect(ContactStore.load().first { $0.id == id } == nil)
        #expect(ContactAdmission.isBlocked(id: id))
        ContactAdmission.unblock(id: id)
        #expect(!ContactAdmission.isBlocked(id: id))
    }

    @Test("надгробие: имя вернулось с другим ключом — тревога и после удаления")
    func tombstoneRaisesResurrectionAlarm() {
        let old = Curve25519.KeyAgreement.PrivateKey().publicKey
        let oldID = Identity.fingerprint(of: old)
        // удалили контакта «Феникс» — осталось надгробие
        ContactAdmission.leaveTombstone(name: "Феникс-тест", id: oldID,
                                        blocked: false)
        defer {
            // надгробия чистятся перезаписью пустым словарём — API
            // удаления нет намеренно (надгробия вечные); тест наводит
            // порядок напрямую
            UserDefaults.standard.removeObject(
                forKey: "contacts.tombstones.v1")
        }

        let newKey = Curve25519.KeyAgreement.PrivateKey().publicKey
        let candidate = Contact(
            id: Identity.fingerprint(of: newKey), name: "Феникс-тест",
            publicKeyBase64: newKey.rawRepresentation.base64EncodedString(),
            addedAt: Date())
        defer { ContactStore.remove(id: candidate.id) }
        let outcome = ContactStore.upsertGuarded(candidate)
        guard case .keyChangeSuspected(let existing, _) = outcome else {
            Issue.record(Comment(rawValue:
                "возврат имени с ДРУГИМ ключом после удаления обязан "
                + "поднять тревогу (B2, надгробие)"))
            return
        }
        #expect(existing.id == oldID, "тревога называет прежний ключ")

        // тот же ключ, что на надгробии, — законное возвращение, тихо
        let sameCandidate = Contact(
            id: oldID, name: "Феникс-тест",
            publicKeyBase64: old.rawRepresentation.base64EncodedString(),
            addedAt: Date())
        defer { ContactStore.remove(id: oldID) }
        let quiet = ContactStore.upsertGuarded(sameCandidate)
        let savedQuiet: Bool = switch quiet {
        case .saved: true
        case .keyChangeSuspected: false
        }
        #expect(savedQuiet, "возврат с ТЕМ ЖЕ ключом тревоги не поднимает")
    }
}
