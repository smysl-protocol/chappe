import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Ack через релей (поле 29.09, скрины владельца): сообщения ДОСТАВЛЕНЫ
// (видны на встречном телефоне), а у отправителя вечное «пока не
// доставлено — ждём собеседника»: flushAcks знал только radio/nearby,
// в форс-«только интернет» подтверждению некуда было уйти.
// ============================================================================

struct RelayAckPathTests {

    @Test("копилка ack помнит, ЧЕЙ это ack — релей адресует в ящик пары")
    func aggregatorKeepsContact() {
        var bag = AckAggregator()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        bag.add(7, contactID: "КОНТАКТ-А", now: t0)
        bag.add(9, contactID: nil, now: t0)   // контакт неизвестен
        let due = bag.takeDueWithContacts(
            now: t0.addingTimeInterval(AckAggregator.maxHold + 1))
        #expect(due.count == 2)
        #expect(due.first(where: { $0.id == 7 })?.contactID == "КОНТАКТ-А",
                Comment(rawValue: "без contactID релейному ack некуда "
                + "адресоваться — в ящик пары кого класть?"))
        #expect(due.first(where: { $0.id == 9 })?.contactID == nil)
    }

    @Test("адрес служебного кадра симметричен: получатель ack его слушает")
    func serviceTargetIsListenedByRecipient() throws {
        // Отправитель ack — «Боб» (принял сообщение), получатель ack —
        // «Алиса» (исходный отправитель). Боб считает адрес от pub
        // Алисы и своего приватного; Алиса слушает пары своих контактов.
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()

        let target = try #require(RelayTransport.serviceTarget(
            peerPub: alice.publicKey.rawRepresentation,
            myPriv: bob),
            "пара вычислима из двух ключей — адрес обязан быть")

        // Мир Алисы: её pairKey с Бобом и её acceptedDsts
        let alicePair = try MailboxID.pairKey(
            myPrivate: alice, peerPublic: bob.publicKey)
        let listened = MailboxID.acceptedDsts(
            myPub: alice.publicKey.rawRepresentation,
            pairKey: alicePair).map(RelayTransport.hex)
        #expect(listened.contains(target.dstHex), Comment(rawValue:
                "ack уйдёт в ящик, который Алиса не слушает, — и статус "
                + "останется «ждём собеседника» навсегда"))

        // Подпись: ключ ящика, который выведет Алиса для этой эпохи,
        // обязан совпасть с приколотым Бобом публичным ключом
        let epoch = MailboxID.epoch(pairKey: alicePair, at: Date())
        let aliceKey = RelayBoxKey.derive(
            recipientPub: alice.publicKey.rawRepresentation,
            pairKey: alicePair, epoch: epoch)
        #expect(aliceKey.publicKey.rawRepresentation == target.boxPublic,
                "иначе её fetch получит 401 об приколотый Бобом ключ")
    }
}
