import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// Долг 1 (WP0/WP2 автономной сессии 02.08): статик-статика в конверте
// НЕТ и не было — E2ESeal с рождения ephemeral-static (свежий X25519 на
// каждый seal). Эти тесты ФИКСИРУЮТ свойство, чтобы регресс к
// статик-статик стал невозможен незаметно.
//
// Границы честности: ECIES даёт forward secrecy по ключу ОТПРАВИТЕЛЯ
// (он в схеме вообще не участвует). Компрометация долговременного
// ключа ПОЛУЧАТЕЛЯ вскрывает записанный архив — это устраняется только
// ratchet/prekeys и является открытым вопросом релея
// (docs/relay_spec_v0.md №1). Тест это НЕ маскирует.
// ============================================================================

nonisolated struct ForwardSecrecyTests {

    @Test("Каждый seal — новый эфемерный ключ (регресс к статик-статик невозможен)")
    func ephemeralKeyIsFreshPerMessage() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let payload = Array("тот же самый текст".utf8)
        let a = try E2ESeal.seal(payload: payload, to: recipient.publicKey)
        let b = try E2ESeal.seal(payload: payload, to: recipient.publicKey)
        // байты 1...32 — публичный эфемерный ключ; обязан различаться
        #expect(Array(a[1...32]) != Array(b[1...32]),
                "эфемерный ключ повторился — это статик-статик")
        // и весь шифротекст различается (свежий nonce + свежий ключ)
        #expect(a != b)
        // а расшифровка обоих даёт исходник
        #expect(try E2ESeal.open(sealed: a, identity: recipient) == payload)
        #expect(try E2ESeal.open(sealed: b, identity: recipient) == payload)
    }

    @Test("FS: долговременный ключ отправителя не расшифровывает записанный трафик")
    func senderKeyCompromiseDoesNotDecryptArchive() throws {
        // Сценарий релея: злоумышленник записал шифротекст (хранится до
        // 48 ч), затем скомпрометировал ДОЛГОВРЕМЕННЫЙ ключ отправителя.
        let senderLongTerm = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        // отправка как в HumanChatStore.enqueueSealed: pubkey отправителя
        // внутри полезной нагрузки
        let inner = Array(senderLongTerm.publicKey.rawRepresentation)
            + [Envelope.codecZlib] + Array("секретный план".utf8)
        let recorded = try E2ESeal.seal(payload: inner,
                                        to: recipient.publicKey)

        // Атакующий владеет: записанным трафиком + статическим ключом
        // отправителя. Попытка открыть трафик этим ключом обязана
        // проваливаться: ключ отправителя в ECDH не участвует.
        #expect(throws: (any Error).self) {
            _ = try E2ESeal.open(sealed: recorded, identity: senderLongTerm)
        }

        // Контроль вменяемости теста: настоящий получатель открывает.
        #expect(try E2ESeal.open(sealed: recorded,
                                 identity: recipient) == inner)
    }

    @Test("Порча любого байта рушит расшифровку (AEAD-целостность)")
    func tamperedCiphertextIsRejected() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let sealed = try E2ESeal.seal(payload: Array("hello".utf8),
                                      to: recipient.publicKey)
        for index in [1, 33, 45, sealed.count - 1] {   // eph, nonce, ct, tag
            var bad = sealed
            bad[index] ^= 0xFF
            #expect(throws: (any Error).self, "байт \(index)") {
                _ = try E2ESeal.open(sealed: bad, identity: recipient)
            }
        }
    }
}
