import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// Рандеву ПЕРВОГО КОНТАКТА через релей (дизайн-дыра 11.08).
//
// Дефект: ящик выводился из ключа ПАРЫ (нужны ОБА ключа). Получатель,
// ещё не знающий ключа отправителя, ящик пары вычислить не мог и не
// слушал — интро незнакомца падало в никем не опрашиваемый ящик.
//
// Замок проверяется СЛОМОМ: если вернуть маршрутизацию интро в ящик
// пары (dst из pairKey), тест rendezvous падает — получатель не
// сопоставляет такой dst со своим ящиком первого контакта.
//
// Ожидания ВНЕШНИЕ: dst считается двумя сторонами НЕЗАВИСИМО (у
// отправителя — из ключа получателя, у получателя — из своего) и
// обязан совпасть; это не вывод из проверяемого кода, а требование
// рандеву.
// ============================================================================

nonisolated struct FirstContactMailboxTests {

    private static func keypair()
    -> (priv: Curve25519.KeyAgreement.PrivateKey,
        pub: Data) {
        let p = Curve25519.KeyAgreement.PrivateKey()
        return (p, p.publicKey.rawRepresentation)
    }

    // Сердце фикса: отправитель считает dst интро из ключа ПОЛУЧАТЕЛЯ
    // (он в QR), получатель — из СВОЕГО; без общего секрета оба обязаны
    // получить ОДИН И ТОТ ЖЕ ящик, иначе интро не встретится.
    @Test("рандеву: dst отправителя из ключа получателя = ящик получателя")
    func sendTargetMeetsRecipientMailbox() {
        let recipient = Self.keypair()
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        // отправитель: знает только публичный ключ получателя (из QR)
        let target = FirstContactMailbox.sendTarget(
            recipientPub: recipient.pub, now: now)

        // получатель: слушает свои ящики первого контакта (из своего pub)
        let mine = FirstContactMailbox.acceptedDsts(myPub: recipient.pub,
                                                    now: now)
        #expect(mine.contains { $0.dst == target.dst }, Comment(rawValue:
                "dst отправителя обязан попасть в приёмное окно получателя "
                + "— иначе интро незнакомца снова падает мимо ящика"))
        #expect(FirstContactMailbox.isMine(target.dst, myPub: recipient.pub,
                                           now: now))
    }

    // Гейт приёмника (dstIsForMe) обязан принять dst первого контакта —
    // иначе, даже долетев, интро отвергается на адресной проверке.
    @Test("dstIsForMe принимает ящик первого контакта без известного контакта")
    func dstIsForMeAcceptsFirstContact() throws {
        // свой ключ в дефолтном сторе теста (TaskLocal-корень)
        try ContactStore.$testStorageRoot.withValue(Self.tempRoot()) {
            let me = Identity.publicKey()
            try #require(me != nil, "нужен свой ключ идентичности")
            let myPub = me!.rawRepresentation
            let now = Date(timeIntervalSince1970: 1_760_000_000)
            let target = FirstContactMailbox.sendTarget(recipientPub: myPub,
                                                        now: now)
            // контактов нет — но свой ящик первого контакта обязан
            // опознаться (иначе handleV2 отвергнет интро незнакомца)
            #expect(DeliveryManager.dstIsForMe(target.dst, now: now),
                    Comment(rawValue:
                    "dst моего ящика первого контакта обязан пройти гейт "
                    + "адресации даже без известного отправителя"))
        }
    }

    // Ящик первого контакта ОТДЕЛЁН от ящика пары: доменная метка не
    // даёт им совпасть — переход на несвязываемый ящик пары реален.
    @Test("ящик первого контакта не совпадает с ящиком пары той же стороны")
    func firstContactDiffersFromPairMailbox() throws {
        let sender = Self.keypair()
        let recipient = Self.keypair()
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        let first = FirstContactMailbox.sendTarget(recipientPub: recipient.pub,
                                                   now: now).dst
        let pairKey = try MailboxID.pairKey(myPrivate: sender.priv,
                                            peerPublic:
            Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.pub))
        let pair = MailboxID.dst(recipientPub: recipient.pub, pairKey: pairKey,
                                 epoch: MailboxID.epoch(pairKey: pairKey, at: now))
        #expect(first != pair, Comment(rawValue:
                "ящики первого контакта и пары обязаны различаться — "
                + "иначе перехода на несвязываемый нет"))
    }

    private static func tempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    // Сквозной приём (сломанная половина): интро незнакомца, адресованное
    // в ЯЩИК ПЕРВОГО КОНТАКТА, доходит до получателя и рождает контакт —
    // то есть у получателя ПОЯВЛЯЕТСЯ ЧАТ (контакт = чат в списке). То же
    // интро с dst ЯЩИКА ПАРЫ (старое поведение) отвергается гейтом
    // адресации (тест ниже) — СЛОМ, доказывающий, что чинит именно ящик
    // первого контакта.
    //
    // Утверждаем СОЗДАНИЕ КОНТАКТА (admit срабатывает ДО дедупа доставки —
    // детерминированно, не зависит от глобального кольца seenMsgIDs).
    // Доставку САМОГО текста в ленту admitted-контакта покрывают
    // ContactAdmissionTests/DeliveryRoutingTests — здесь важен факт
    // «интро долетело и признано своим», а не повторная проверка ленты.
    @MainActor
    @Test("интро незнакомца в ящик первого контакта рождает контакт (чат)")
    func firstContactIntroCreatesContact() throws {
        try ContactStore.$testStorageRoot.withValue(Self.tempRoot()) {
            let me = try #require(Identity.publicKey())
            let myPub = me.rawRepresentation
            // РЕАЛЬНОЕ now: ingest внутри зовёт dstIsForMe(now: Date()),
            // а dst зависит от эпохи — фиксированное прошлое не совпало бы
            let now = Date()

            // отправитель-незнакомец: свежая пара, у получателя его нет
            let senderPriv = Curve25519.KeyAgreement.PrivateKey()
            let senderRaw = Array(senderPriv.publicKey.rawRepresentation)
            let senderID = Identity.fingerprint(of: senderPriv.publicKey)
            #expect(ContactStore.load().first { $0.id == senderID } == nil,
                    "до интро контакта незнакомца быть не должно")

            // интро — рукопожатие рэтчета, несущее первое сообщение
            let (codec, data) = TextCodec.best("привет это первый контакт")
            let seed = (0..<32).map { _ in UInt8.random(in: 0...255) }
            let handshake = try RatchetHandshake.make(
                seed: seed, to: me, myPub: senderRaw,
                innerCodec: codec, data: data,
                sentAtMinutes: UInt32(now.timeIntervalSince1970 / 60))

            // адресуем в ЯЩИК ПЕРВОГО КОНТАКТА получателя
            let fcDst = FirstContactMailbox.sendTarget(recipientPub: myPub,
                                                       now: now).dst
            let packets = try EnvelopeV2.encodePackets(
                msgID: UInt16.random(in: 1...0xFFFE),
                stream: handshake, dst: fcDst)
            for p in packets { DeliveryManager.shared.ingest(WirePadding.pad(p)) }

            #expect(ContactStore.load().first { $0.id == senderID } != nil,
                    Comment(rawValue:
                    "интро незнакомца через ящик первого контакта обязано "
                    + "родить контакт (=чат) — раньше терялось в никем не "
                    + "опрашиваемом ящике пары"))
        }
    }

    // Полевой дефект 13.08: ПЕРВОЕ сообщение терялось. Реальный
    // отправитель (enqueueSealed, v1-путь) шлёт текст НЕ рукопожатием,
    // а v2-sealed-кадром [ts 4][pub 32][кодек][данные] (+ отдельную
    // ПУСТУЮ пробу рукопожатия). Приём v2-sealed вычислял отпечаток,
    // но не отдавал deliver сырой ключ — admit не звался, незнакомца
    // в контактах нет, текст падал в демо-ленту (chat_demo.json).
    // Кадр здесь построен КАК У ОТПРАВИТЕЛЯ — ожидание внешнее
    // (байтовая раскладка сборщика исходящих, не приёмного кода).
    // Слом: убрать передачу ключа из v2-sealed-ветки processV2Stream —
    // текст снова уедет в демо-ленту, тест краснеет.
    @MainActor
    @Test("первый v2-sealed кадр незнакомца: контакт И текст в его чате")
    func firstSealedFrameDeliversContactAndText() throws {
        try ContactStore.$testStorageRoot.withValue(Self.tempRoot()) {
            let me = try #require(Identity.publicKey())
            let myPub = me.rawRepresentation
            let now = Date()

            let senderPriv = Curve25519.KeyAgreement.PrivateKey()
            let senderRaw = Array(senderPriv.publicKey.rawRepresentation)
            let senderID = Identity.fingerprint(of: senderPriv.publicKey)
            // маркер уникален: демо-лента общая для тест-раннера
            let text = "первый контакт \(UUID().uuidString.prefix(8))"
            defer {
                HumanChatStore.purge(contactID: senderID)
                let demo = HumanChatStore.loadLog(contactID: nil)
                    .filter { !$0.text.contains(text) }
                HumanChatStore.saveLog(demo, contactID: nil)
            }

            let (codec, data) = TextCodec.best(text)
            let ts = UInt32(now.timeIntervalSince1970 / 60)
            let relayInner: [UInt8] = [UInt8(ts & 0xFF),
                                       UInt8((ts >> 8) & 0xFF),
                                       UInt8((ts >> 16) & 0xFF),
                                       UInt8(ts >> 24)]
                + senderRaw + [codec] + data
            let sealed = try E2ESeal.seal(payload: relayInner, to: me)
            let dst = FirstContactMailbox.sendTarget(recipientPub: myPub,
                                                     now: now).dst
            let packets = try EnvelopeV2.encodePackets(
                msgID: UInt16.random(in: 1...0xFFFE),
                stream: sealed, dst: dst)
            for p in packets { DeliveryManager.shared.ingest(WirePadding.pad(p)) }

            #expect(ContactStore.load().first { $0.id == senderID } != nil,
                    Comment(rawValue:
                    "v2-sealed несёт ключ отправителя — неизвестный ключ "
                    + "обязан родить контакт (B2), как и рукопожатие"))
            let log = HumanChatStore.loadLog(contactID: senderID)
            #expect(log.contains { $0.kind == .incoming
                        && $0.text.contains(text) },
                    Comment(rawValue:
                    "текст ПЕРВОГО кадра обязан лечь в чат нового контакта "
                    + "— полевой дефект 13.08: он падал в демо-ленту"))
            #expect(!HumanChatStore.loadLog(contactID: nil)
                        .contains { $0.text.contains(text) },
                    "в демо-ленту первый текст попадать не должен")
        }
    }

    @MainActor
    @Test("СЛОМ: то же интро в ящик ПАРЫ отвергается — контакт не рождается")
    func introToPairMailboxIsRejected() throws {
        try ContactStore.$testStorageRoot.withValue(Self.tempRoot()) {
            let me = try #require(Identity.publicKey())
            let myPub = me.rawRepresentation
            let myPriv = try #require(Identity.privateKey())
            // РЕАЛЬНОЕ now (см. соседний тест): слом честен только если
            // разница — ТОЛЬКО ящик (пара vs первый контакт), не эпоха
            let now = Date()

            let senderPriv = Curve25519.KeyAgreement.PrivateKey()
            let senderRaw = Array(senderPriv.publicKey.rawRepresentation)
            let senderID = Identity.fingerprint(of: senderPriv.publicKey)

            let (codec, data) = TextCodec.best("привет это первый контакт")
            let seed = (0..<32).map { _ in UInt8.random(in: 0...255) }
            let handshake = try RatchetHandshake.make(
                seed: seed, to: me, myPub: senderRaw,
                innerCodec: codec, data: data,
                sentAtMinutes: UInt32(now.timeIntervalSince1970 / 60))

            // dst ЯЩИКА ПАРЫ (как слал сломанный код) — получатель ключа
            // отправителя не знает, этот dst со своими ящиками не сходится
            let pairKey = try MailboxID.pairKey(myPrivate: myPriv,
                                                peerPublic: senderPriv.publicKey)
            let pairDst = MailboxID.dst(recipientPub: myPub, pairKey: pairKey,
                                        epoch: MailboxID.epoch(pairKey: pairKey,
                                                               at: now))
            let packets = try EnvelopeV2.encodePackets(
                msgID: 0x4343, stream: handshake, dst: pairDst)
            for p in packets { DeliveryManager.shared.ingest(WirePadding.pad(p)) }

            #expect(ContactStore.load().first { $0.id == senderID } == nil,
                    Comment(rawValue:
                    "интро с dst ящика пары обязано отвергнуться гейтом "
                    + "адресации — это и была дыра первого контакта"))
        }
    }
}
