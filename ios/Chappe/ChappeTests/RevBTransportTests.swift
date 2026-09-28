import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Замки транспортной половины шва рев B (мега-4, 14.08).
// Кадры второй стороны собираются РУКАМИ по спеке шва (внешнее
// ожидание), не выводом отправного кода.
// ============================================================================

@Suite(.serialized)   // общие PeerCaps/SeqStore/очередь
struct RevBTransportTests {

    /// Свежий контакт-собеседник с ключом.
    @MainActor
    private func makePeer(name: String)
    -> (contact: Contact, priv: Curve25519.KeyAgreement.PrivateKey) {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let contact = Contact(
            id: Identity.fingerprint(of: priv.publicKey), name: name,
            publicKeyBase64: priv.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: Date(), verified: false)
        ContactStore.upsert(contact)
        return (contact, priv)
    }

    @MainActor
    private func cleanup(_ contact: Contact) {
        Outbox.mutateQueue { $0.removeAll { $0.contactID == contact.id } }
        HumanChatStore.saveLog([], contactID: contact.id)
        ContactStore.remove(id: contact.id)
        SeqStore.purge(contactID: contact.id)
        PeerCaps.purge(contactID: contact.id)
        RatchetStore.drop(contactID: contact.id)
    }

    // Подпись п.1/п.5: собеседник без доказанного рев B получает
    // СТАРЫЙ путь (кодек 3 на релее). Слом: убрать гейт caps — красный.
    @MainActor
    @Test("без подтверждения рев B отправка остаётся кодеком 3")
    func legacyPathWithoutCaps() throws {
        let (contact, _) = makePeer(name: "Легаси")
        defer { cleanup(contact) }
        let queued = try Outbox.enqueueSealed(
            innerCodec: Envelope.codecStore,
            data: Array("привет".utf8), to: contact, entryID: UUID())
        let stream = Outbox.bytes(fromHex: try #require(queued.relayStreamHex))
        #expect(stream.first == E2ESeal.codecSealed, Comment(rawValue:
                "непроверенному пиру шлём замороженный кодек 3 — старые "
                + "сборки обязаны продолжать читать нас (WP3)"))
    }

    // Подпись п.1: известная пара, рев B доказан, сессии нет → кодек 5
    // со swеж seq; вторая отправка — seq+1. Слом: убрать ветку 5 — красный.
    @MainActor
    @Test("пара с рев B без сессии шлёт кодек 5, seq монотонен")
    func revBPairSendsSealed2() throws {
        let (contact, peerPriv) = makePeer(name: "Пара5")
        defer { cleanup(contact) }
        PeerCaps.markRevB(contactID: contact.id)

        func sendAndOpen(_ text: String) throws -> RevBPrefix {
            let queued = try Outbox.enqueueSealed(
                innerCodec: Envelope.codecStore,
                data: Array(text.utf8), to: contact, entryID: UUID())
            let stream = Outbox.bytes(
                fromHex: try #require(queued.relayStreamHex))
            #expect(stream.first == EnvelopeRevB.codecSealed2)
            // вскрытие стороной получателя: его ключ + мой публичный
            let opened = try E2ESeal2.open(
                sealed: stream, identity: peerPriv,
                senderPub: try #require(Identity.publicKey()))
            return try RevBPrefix.decode(opened)
        }
        let first = try sendAndOpen("раз")
        let second = try sendAndOpen("два")
        #expect(String(decoding: first.data, as: UTF8.self) == "раз")
        #expect(first.seq == 1 && second.seq == 2, Comment(rawValue:
                "seq присваивается с msgID и монотонен — на нём порядок "
                + "ленты (подпись п.2)"))
        #expect(first.sentAtSeconds > 1_700_000_000,
                "метка — честные unix-секунды, не минуты")
    }

    // Подпись п.5: живая сессия + session2-кадр собеседника → кодек 6.
    @MainActor
    @Test("живая сессия с подтверждением session2 шлёт кодек 6")
    func sessionSendsCodec6() throws {
        let (contact, _) = makePeer(name: "Сессия6")
        defer { cleanup(contact) }
        PeerCaps.markSession2(contactID: contact.id)
        // парные эпохи одного сида: мой — инициатор, приёмный — нет
        let seed = (0..<32).map { _ in UInt8.random(in: 0...255) }
        var mine = RatchetEpoch(seed: seed, iAmInitiator: true)
        mine.peerConfirmedV2 = true
        RatchetStore.save(mine, contactID: contact.id)
        var theirs = RatchetEpoch(seed: seed, iAmInitiator: false)

        let queued = try Outbox.enqueueSealed(
            innerCodec: Envelope.codecStore,
            data: Array("шесть".utf8), to: contact, entryID: UUID())
        let stream = Outbox.bytes(fromHex: try #require(queued.relayStreamHex))
        #expect(stream.first == EnvelopeRevB.codecSession2, Comment(
                rawValue: "подтверждённая session2-пара обязана ехать "
                + "кодеком 6 (подпись п.1)"))
        let message = try theirs.openMessage2(stream: stream)
        #expect(String(decoding: message.data, as: UTF8.self) == "шесть")
        #expect(message.seq >= 1)
    }

    // Приёмник кодека 5: кадр от пира открывается, PeerCaps растёт,
    // лента получает секунды+seq. Слом: убрать ветку 5 приёмника.
    @MainActor
    @Test("приёмник открывает кодек 5, метит revB и датирует секундами")
    func receiverOpensSealed2() throws {
        let (contact, peerPriv) = makePeer(name: "Приём5")
        defer { cleanup(contact) }
        let myPriv = try #require(Identity.privateKey())
        let myPub = try #require(Identity.publicKey())

        // кадр руками ЗА пира: его статика + мой ключ, тег Т1
        let pairKey = try MailboxID.pairKey(myPrivate: myPriv,
                                            peerPublic: peerPriv.publicKey)
        let epoch = MailboxID.epoch(pairKey: pairKey, at: Date())
        let sentAt = UInt32(Date().timeIntervalSince1970) - 120
        let prefix = RevBPrefix(sentAtSeconds: sentAt, seq: 41,
                                innerCodec: Envelope.codecStore,
                                data: Array("рев-б письмо".utf8))
        let stream = try E2ESeal2.seal(
            plaintext: prefix.encode(), sender: peerPriv, to: myPub,
            tag: E2ESeal2.senderTag(pairKey: pairKey, epoch: epoch))
        let packet = try #require(try EnvelopeV2.encodePackets(
            msgID: Envelope.newMsgID(), stream: stream).first)
        DeliveryManager.shared.handleV2(packet, via: "lan")

        let entry = try #require(HumanChatStore.loadLog(contactID: contact.id)
            .first { $0.text.contains("рев-б письмо") })
        #expect(PeerCaps.load(contactID: contact.id).revB, Comment(
                rawValue: "кадр 5 обязан доказать рев B (подпись п.5)"))
        #expect(!PeerCaps.load(contactID: contact.id).session2,
                "кадр 5 эпоху НЕ доказывает")
        #expect(abs(entry.date.timeIntervalSince1970
                    - Double(sentAt) - 0.041) < 0.5, Comment(rawValue:
                "дата пузыря — честные секунды отправки + доли seq"))
        #expect(entry.receivedVia == "lan")
    }

    // Кодек 7 внутри 5: позиция уходит в PeerPositionStore, не в ленту;
    // старый seq — реплей, отброшен. Слом: убрать маршрутизацию 7.
    @MainActor
    @Test("позиция кодека 7 — в стор с реплей-защитой, не в ленту")
    func positionRoutedWithReplayGuard() throws {
        let (contact, peerPriv) = makePeer(name: "Гео7")
        defer {
            cleanup(contact)
            PeerPositionStore.shared.removePosition(for: contact.id)
        }
        let myPriv = try #require(Identity.privateKey())
        let myPub = try #require(Identity.publicKey())
        let pairKey = try MailboxID.pairKey(myPrivate: myPriv,
                                            peerPublic: peerPriv.publicKey)
        let epoch = MailboxID.epoch(pairKey: pairKey, at: Date())

        func positionFrame(lat: Double, seq: UInt32) throws -> [UInt8] {
            let payload = try PositionPayload(
                precision: 0, lat: lat, lon: 108.25,
                measuredAt: UInt32(Date().timeIntervalSince1970)).encode()
            let prefix = RevBPrefix(
                sentAtSeconds: UInt32(Date().timeIntervalSince1970),
                seq: seq, innerCodec: EnvelopeRevB.codecPosition,
                data: Array(payload.dropFirst()))
            let stream = try E2ESeal2.seal(
                plaintext: prefix.encode(), sender: peerPriv, to: myPub,
                tag: E2ESeal2.senderTag(pairKey: pairKey, epoch: epoch))
            return try #require(try EnvelopeV2.encodePackets(
                msgID: Envelope.newMsgID(), stream: stream).first)
        }

        DeliveryManager.shared.handleV2(try positionFrame(lat: 12.5,
                                                          seq: 10),
                                        via: "lan")
        let stored = try #require(
            PeerPositionStore.shared.positions[contact.id],
            "позиция обязана лечь в PeerPositionStore (подпись п.4)")
        #expect(abs(stored.lat - 12.5) < 0.001)
        #expect(HumanChatStore.loadLog(contactID: contact.id).isEmpty,
                "позиция — не пузырь в ленте")

        // реплей: старый seq не переигрывает свежую точку
        DeliveryManager.shared.handleV2(try positionFrame(lat: 55.0,
                                                          seq: 9),
                                        via: "lan")
        let after = try #require(
            PeerPositionStore.shared.positions[contact.id])
        #expect(abs(after.lat - 12.5) < 0.001, Comment(rawValue:
                "позиция со старым seq обязана быть отброшена — релей "
                + "не переигрывает устаревшую точку (шов №4)"))
    }
}

// ============================================================================
// T4: FRAG2, гейт больших сообщений, sunset открытого 0x5.
// ============================================================================

@Suite(.serialized)
struct RevBFrag2Tests {

    // Гейт «16≠255»: >255 кусков (FRAG2) — только собеседнику с рев B.
    // Слом: убрать гейт из enqueueSealed — красный.
    @Test("FRAG2-объём разрешён только пирам с рев B")
    func bigMessageGate() {
        #expect(Outbox.bigMessageAllowed(chunks: 255, peerRevB: false),
                "≤255 кусков собирают все живые сборки (v2-тракт без капа 16)")
        #expect(!Outbox.bigMessageAllowed(chunks: 256, peerRevB: false),
                Comment(rawValue: "FRAG2 старые приёмники честно отвергают "
                + "— слать нельзя, отказ честный (закрытие 16≠255)"))
        #expect(Outbox.bigMessageAllowed(chunks: 256, peerRevB: true))
    }

    // Сквозной FRAG2: большой кадр кодека 5 нарезается битом 5,
    // приёмник собирает пул-ассемблером и вскрывает AEAD над целым.
    // Слом: убрать ветку frag2 из handleV2 — красный.
    @MainActor
    @Test("FRAG2 сквозняком: >255 кусков собираются и вскрываются")
    func frag2EndToEnd() throws {
        let peerPriv = Curve25519.KeyAgreement.PrivateKey()
        let contact = Contact(
            id: Identity.fingerprint(of: peerPriv.publicKey), name: "Гигант",
            publicKeyBase64: peerPriv.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: Date(), verified: false)
        ContactStore.upsert(contact)
        defer {
            HumanChatStore.saveLog([], contactID: contact.id)
            ContactStore.remove(id: contact.id)
            SeqStore.purge(contactID: contact.id)
            PeerCaps.purge(contactID: contact.id)
        }
        let myPriv = try #require(Identity.privateKey())
        let myPub = try #require(Identity.publicKey())
        let pairKey = try MailboxID.pairKey(myPrivate: myPriv,
                                            peerPublic: peerPriv.publicKey)
        let epoch = MailboxID.epoch(pairKey: pairKey, at: Date())

        // данные, гарантированно требующие >255 кусков (~50 КБ)
        let marker = Array("ГИГАНТ-МАРКЕР".utf8)
        let big = marker + [UInt8](repeating: 0x2E, count: 50_000)
        let prefix = RevBPrefix(
            sentAtSeconds: UInt32(Date().timeIntervalSince1970),
            seq: 1, innerCodec: Envelope.codecStore, data: big)
        let stream = try E2ESeal2.seal(
            plaintext: prefix.encode(), sender: peerPriv, to: myPub,
            tag: E2ESeal2.senderTag(pairKey: pairKey, epoch: epoch))
        let packets = try EnvelopeV2.encodePackets(
            msgID: Envelope.newMsgID(), stream: stream)
        try #require(packets.count > 255, "нарезка обязана уйти в FRAG2")

        for packet in packets {
            DeliveryManager.shared.handleV2(packet, via: "lan")
        }
        let entry = HumanChatStore.loadLog(contactID: contact.id)
            .first { $0.kind == .incoming }
        #expect(entry != nil, Comment(rawValue:
                "FRAG2-сообщение обязано собраться пулом и вскрыться — "
                + "иначе потолок ~45 КБ остался (B3)"))
    }

    // Подпись п.6: приём открытого 0x5 гаснет кодом после срока.
    // Слом: убрать guard sunset из handleLocation — красный.
    @MainActor
    @Test("открытый 0x5 после срока снятия гасится кодом")
    func locationV0SunsetCloses() throws {
        let peer = Curve25519.KeyAgreement.PrivateKey()
        let contact = Contact(
            id: Identity.fingerprint(of: peer.publicKey), name: "Санс",
            publicKeyBase64: peer.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: Date(), verified: false)
        ContactStore.upsert(contact)
        defer {
            ContactStore.remove(id: contact.id)
            PeerPositionStore.shared.removePosition(for: contact.id)
        }
        // канонический v0-LOCATION (ровно один контакт — атрибуция 1:1)
        let msgID = Envelope.newMsgID()
        let body = try Envelope.encodeFineCoords(lat: 11.5, lon: 108.1)
        let packet = Envelope.encodeHeader(
            msgClass: Envelope.classLocation,
            flags: Envelope.flagHasCoords, msgID: msgID) + body
        let header = (msgClass: Envelope.classLocation,
                      flags: Envelope.flagHasCoords, msgID: msgID)

        let afterSunset = DeliveryManager.locationV0Sunset
            .addingTimeInterval(60)
        DeliveryManager.shared.handleLocation(packet, header: header,
                                              now: afterSunset)
        #expect(PeerPositionStore.shared.positions[contact.id] == nil,
                Comment(rawValue: "открытый 0x5 после срока обязан "
                + "гаснуть КОДОМ (подпись п.6, образец v1ReplySunset)"))
    }
}

// ============================================================================
// МЕГА-5 (фаза 3): геометка видна И В ЧАТЕ. Сквозняк «кодек 7 → стор →
// карта» держат замки выше (positionRoutedWithReplayGuard: тот же стор
// читает MapScreen); здесь — чатовая половина: строка чипа.
// Слом: убрать peerPositionLine/чип из HumanChatView — красный.
// ============================================================================

nonisolated struct PeerPositionChipTests {

    @Test("чип позиции собеседника: литералы возраста руками")
    func chipLineByHand() {
        #expect(HumanChatView.peerPositionLine(fixAge: 10)
                == "Позиция собеседника: только что · на карте")
        #expect(HumanChatView.peerPositionLine(fixAge: 300)
                == "Позиция собеседника: 5 мин назад · на карте")
        #expect(HumanChatView.peerPositionLine(fixAge: 7200)
                == "Позиция собеседника: 2 ч назад · на карте", Comment(
                rawValue: "мега-5: геометка обязана быть видна В ЧАТЕ — "
                + "раньше стор читала только карта"))
        #expect(HumanChatView.peerPositionLine(fixAge: -5)
                == "Позиция собеседника: только что · на карте",
                "часы из будущего клэмпятся")
    }
}
