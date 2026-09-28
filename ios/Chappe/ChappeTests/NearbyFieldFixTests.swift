import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Замки на полевые дефекты прогона двух телефонов 08.08.2026:
//  1) один текст пришёл дважды под разными msgID (14678 и 25298) —
//     session-ветка очереди кодировала пакеты одним msgID, а очередь
//     (и релейную рамку) вела под другим;
//  2) сосед повторял сообщение 20 минут — ack не ставился вовсе,
//     потому что копилка требовала непустой peerHost (реликт LAN);
//  3) сообщение из 3 пакетов не дошло по BLE — залп write-without-
//     response молча терял куски в переполненной очереди CoreBluetooth;
//  4) повторно доставленное рукопожатие (релей отдаёт at-least-once)
//     сбрасывало живую эпоху рэтчета — заново открывались уже
//     прочитанные сообщения;
//  5) подсказка «Демо-чат…» показывалась в пустом чате живого контакта.
// Ожидания выведены из полевых фактов (дневник транспорта, контейнер
// телефона), не из проверяемого кода.
// ============================================================================

struct NearbyFieldFixTests {

    // MARK: 1. Один msgID обоими путями (session-ветка)

    @Test("session-ветка: msgID очереди совпадает с msgID пакетов")
    @MainActor
    func sessionQueueAndPacketsShareMsgID() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let contact = Contact(
            id: Identity.fingerprint(of: recipient.publicKey),
            name: "Тест-дубль",
            publicKeyBase64: recipient.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: Date())
        // подтверждённая эпоха → enqueueSealed пойдёт session-веткой
        var epoch = RatchetEpoch(seed: Array(repeating: 7, count: 32),
                                 iAmInitiator: true)
        epoch.peerConfirmedV2 = true
        RatchetStore.save(epoch, contactID: contact.id)
        let entryID = UUID()
        defer {
            RatchetStore.drop(contactID: contact.id)
            Outbox.saveQueueRaw(Outbox.loadQueueRaw()
                .filter { $0.entryID != entryID })
        }

        let queued = try Outbox.enqueueSealed(
            innerCodec: Envelope.codecStore,
            data: Array("проверка".utf8),
            to: contact, entryID: entryID)

        for packetHex in queued.packetsHex {
            let frame = try EnvelopeV2.decode(Outbox.bytes(fromHex: packetHex))
            #expect(frame.msgID == queued.msgID, Comment(rawValue:
                    "msgID пакета \(frame.msgID) ≠ msgID очереди "
                    + "\(queued.msgID): релейная копия уедет под другим "
                    + "msgID — дедуп получателя её не погасит (полевой "
                    + "дубль 08.08), а ack не найдёт запись очереди"))
        }
    }

    // MARK: 2. Ack ставится и при пустом peerHost

    @Test("подтверждение доставки не требует peerHost")
    @MainActor
    func ackQueuedWithoutPeerHost() throws {
        let dm = DeliveryManager.shared
        let savedKind = dm.transportKind
        let savedHost = dm.peerHost
        dm.transportKind = "demo"
        dm.peerHost = ""     // на телефонах он пуст всегда
        dm.pendingAcks = AckAggregator()
        defer {
            dm.pendingAcks = AckAggregator()
            dm.transportKind = savedKind
            dm.peerHost = savedHost
            // не сорить в демо-ленту тестового хоста
            let log = HumanChatStore.loadLog(contactID: nil)
                .filter { $0.text != "проверка подтверждения 08.08" }
            HumanChatStore.saveLog(log, contactID: nil)
        }

        let msgID = Envelope.newMsgID()
        let packets = try TextEncoder.encode(
            msgID: msgID, text: "проверка подтверждения 08.08",
            wantAck: true)
        dm.ingest(packets[0])

        #expect(dm.pendingAcks.pending.contains(msgID), Comment(rawValue:
                "входящее с просьбой подтверждения обязано класть ack "
                + "в копилку и без peerHost — иначе сосед повторяет "
                + "сообщение вечно (дневник 08.08: 12 повторов за 20 минут)"))
    }

    // MARK: 3. BLE-куски ждут канала, а не теряются

    @Test("backlog пишет только пока канал принимает, порядок цел")
    func backlogRespectsBackpressure() {
        var backlog = BleChunkBacklog()
        let peer = UUID()
        let chunks: [[UInt8]] = (0..<5).map { [UInt8($0)] }
        backlog.add(chunks, for: peer)

        var written: [[UInt8]] = []
        var budget = 2                        // канал принял два и закрылся
        backlog.drain(for: peer,
                      canSend: { budget > 0 },
                      write: { written.append($0); budget -= 1 })
        #expect(written == [[0], [1]],
                "писать можно только пока canSend, и строго по порядку")
        #expect(backlog.pendingCount(for: peer) == 3, Comment(rawValue:
                "непринятые куски обязаны ждать, а не пропадать "
                + "(так 08.08 потерялось сообщение из 3 пакетов)"))

        // канал снова готов (peripheralIsReady) — хвост доливается
        backlog.drain(for: peer, canSend: { true },
                      write: { written.append($0) })
        #expect(written == chunks, "после возобновления дошло всё и по порядку")
        #expect(backlog.pendingCount(for: peer) == 0)
    }

    // Полевое 13.08: «передан по nearby» каждые 60 с без единого ack —
    // completion(state == .connected) выдавал успех, когда куски ещё
    // лежали в backlog (и умирали при обрыве). Теперь последний кусок
    // пакета — подтверждаемый (.withResponse), успех несёт ТОЛЬКО ответ
    // didWriteValueFor. Слом: вернуть completion по state — замок
    // писем-ожиданий (ledger) не задействуется и краснеет.
    @Test("подтверждаемый кусок — последний, порядок с обычными цел")
    func backlogMarksLastChunkForConfirmation() {
        var backlog = BleChunkBacklog()
        let peer = UUID()
        backlog.add([[1], [2], [3]], confirmLast: true, for: peer)

        var plain: [[UInt8]] = []
        var confirmed: [[UInt8]] = []
        backlog.drain(for: peer, canSend: { true },
                      write: { plain.append($0) },
                      writeConfirmed: { confirmed.append($0) })
        #expect(plain == [[1], [2]], "обычные куски — write, по порядку")
        #expect(confirmed == [[3]], Comment(rawValue:
                "ПОСЛЕДНИЙ кусок обязан уйти подтверждаемой записью — "
                + "только его ответ означает «сосед принял пакет»"))
        #expect(backlog.pendingCount(for: peer) == 0)

        // совместимость: add без confirmLast не рождает подтверждаемых
        backlog.add([[9]], for: peer)
        confirmed = []
        backlog.drain(for: peer, canSend: { true },
                      write: { _ in }, writeConfirmed: { confirmed.append($0) })
        #expect(confirmed.isEmpty, "без confirmLast подтверждений нет")
    }

    @Test("ledger: ответы паруются FIFO, обрыв проваливает все ожидания")
    func confirmLedgerPairsFIFOAndFailsOnDisconnect() {
        var ledger = BleConfirmLedger()
        let peer = UUID()
        nonisolated(unsafe) var outcomes: [String] = []
        ledger.register(peer: peer) { outcomes.append("A:\($0)") }
        ledger.register(peer: peer) { outcomes.append("B:\($0)") }

        ledger.confirmOldest(peer: peer, ok: true)
        #expect(outcomes == ["A:true"], Comment(rawValue:
                "ответ обязан выстрелить СТАРЕЙШЕЕ ожидание — иначе "
                + "провал одного куска дёргает completion чужого пакета"))

        ledger.register(peer: peer) { outcomes.append("C:\($0)") }
        ledger.failAll(peer: peer)
        #expect(outcomes == ["A:true", "B:false", "C:false"], Comment(
                rawValue: "обрыв соединения обязан провалить ВСЕ ожидания "
                + "соседа — молчание мёртвого линка не есть успех"))
        #expect(ledger.pendingCount(peer: peer) == 0)

        // ответ без ожиданий — тишина, не краш (поздний didWriteValueFor)
        ledger.confirmOldest(peer: peer, ok: true)
        #expect(outcomes.count == 3)
    }

    @Test("потолок backlog: старое роняется со счётом, роста без края нет")
    func backlogCapDropsOldest() {
        var backlog = BleChunkBacklog()
        let peer = UUID()
        backlog.add((0..<BleChunkBacklog.capacity + 10).map {
            [UInt8($0 & 0xFF)]
        }, for: peer)
        #expect(backlog.pendingCount(for: peer) == BleChunkBacklog.capacity)
        #expect(backlog.dropped == 10, "потеря обязана быть посчитана")

        backlog.forget(peer)
        #expect(backlog.pendingCount(for: peer) == 0,
                "разрыв соединения чистит очередь соседа")
    }

    // MARK: 3б. Изоляция рук «рядом» (условие владельца, 13.08)

    // Wi-Fi Aware без пар обязан молча НЕ подняться, не уронив ни
    // приложение, ни BLE-руку: setActive поднимает обе руки, Aware
    // гейтится hasPairedDevices (в тестовой среде пар нет), отправка
    // без соседей — честный false, не краш и не вечное молчание.
    // Слом: если Aware-инициализация начнёт бросать/ронять при
    // отсутствии пар или сервиса — смоук падает первым.
    @MainActor
    @Test("Aware без пар не поднимается и не гасит BLE-руку")
    func awareAbsenceLeavesNearbyAlive() async throws {
        let nearby = NearbyTransport.shared
        nearby.setActive(true)
        // дать стартовым Task-ам (в т.ч. hasPairedDevices) отработать
        try await Task.sleep(for: .milliseconds(300))
        let outcome = await withCheckedContinuation { done in
            nearby.send([1, 2, 3]) { ok in done.resume(returning: ok) }
        }
        #expect(outcome == false, Comment(rawValue:
                "без соседей отправка обязана честно вернуть false — "
                + "сбой Aware-руки не смеет превращаться в краш/молчание"))
        nearby.setActive(false)
        #expect(nearby.peerCount == 0, "остановка чистит соседей")
    }

    // MARK: 4. Повтор рукопожатия не сбрасывает живую эпоху

    @Test("повторный probe (at-least-once релея) не обнуляет счётчики")
    @MainActor
    func replayedHandshakeKeepsEpoch() throws {
        let identity = try #require(Identity.privateKey())
        let myPub = try #require(Identity.publicKey())
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let senderID = Identity.fingerprint(of: sender.publicKey)
        let contact = Contact(
            id: senderID, name: "Тест-повтор",
            publicKeyBase64: sender.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: Date())
        ContactStore.save(ContactStore.load() + [contact])
        defer {
            ContactStore.remove(id: senderID)
            RatchetStore.drop(contactID: senderID)
        }

        let seed = Outbox.randomSeed()
        let probe = try RatchetHandshake.make(
            seed: seed, to: myPub,
            myPub: Array(sender.publicKey.rawRepresentation),
            innerCodec: Envelope.codecStore, data: [],
            sentAtMinutes: 1)
        let packet = try EnvelopeV2.encodePackets(
            msgID: Envelope.newMsgID(), stream: probe)[0]

        DeliveryManager.shared.ingest(packet)
        var epoch = try #require(RatchetStore.load(contactID: senderID),
                                 "первый probe обязан создать эпоху")
        _ = identity   // identity нужен только чтобы probe был вскрываем

        // сессия пожила: счётчик приёма ушёл вперёд
        epoch.recvNext = 5
        RatchetStore.save(epoch, contactID: senderID)

        // релей отдал тот же probe второй раз (at-least-once)
        DeliveryManager.shared.ingest(packet)
        let after = try #require(RatchetStore.load(contactID: senderID))
        #expect(after.recvNext == 5, Comment(rawValue:
                "повтор того же рукопожатия сбросил эпоху: заново "
                + "откроются уже прочитанные сообщения (дубль 08.08)"))
    }

    // MARK: 5. Слово пути — факт, релей его не перекрашивает

    @Test("«рядом» не перетирается релеем ни укладкой, ни забором")
    @MainActor
    func relayDoesNotRepaintNearby() throws {
        // собственная лента, НЕ демо-лог (contactID nil): его целиком
        // переписывают соседние тесты, и под нагрузкой запись пропадала
        // между их load и save (флак сюиты 08.08)
        let cid = "тест-путь-0808"
        var entry = ChatEntry(kind: .outgoing, text: "путь-проверка 08.08")
        entry.sentAt = Date()
        entry.sentVia = "nearby"          // сосед уже принял отправку
        entry.deliveredAt = Date()        // и ack уже пришёл
        var log = HumanChatStore.loadLog(contactID: cid)
        log.append(entry)
        HumanChatStore.saveLog(log, contactID: cid)
        let queued = Outbox.enqueueRaw(packets: [], msgID: Envelope.newMsgID(),
                                       entryID: entry.id, contactID: cid,
                                       expectAck: true)
        defer {
            Outbox.saveQueueRaw(Outbox.loadQueueRaw()
                .filter { $0.entryID != entry.id })
            HumanChatStore.saveLog([], contactID: cid)
        }

        // Сценарий А: отправлено «рядом», ещё НЕ доставлено — укладка
        // в ящик не смеет перекрасить путь
        var log2 = HumanChatStore.loadLog(contactID: cid)
        if let i = log2.firstIndex(where: { $0.id == entry.id }) {
            log2[i].deliveredAt = nil
            HumanChatStore.saveLog(log2, contactID: cid)
        }
        DeliveryManager.shared.relayStored(queued, dstHex: "00", epoch: 0,
                                           framesHex: [])
        let afterStore = try #require(HumanChatStore.loadLog(contactID: cid)
            .first { $0.id == entry.id })
        #expect(afterStore.sentVia == "nearby", Comment(rawValue:
                "укладка в ящик перекрасила уже случившуюся отправку "
                + "соседу (полевой прогон 08.08)"))

        // Сценарий Б: ack соседа уже подтвердил доставку — забор кадра
        // из ящика лишь подчистил дубль
        log2 = HumanChatStore.loadLog(contactID: cid)
        if let i = log2.firstIndex(where: { $0.id == entry.id }) {
            log2[i].deliveredAt = Date()
            HumanChatStore.saveLog(log2, contactID: cid)
        }
        DeliveryManager.shared.relayDelivered(queued)

        let after = try #require(HumanChatStore.loadLog(contactID: cid)
            .first { $0.id == entry.id })
        #expect(after.sentVia == "nearby", Comment(rawValue:
                "лента говорила «через интернет», когда доставил «рядом»: "
                + "укладка в ящик и забор дубля перекрашивали факт "
                + "(полевой прогон 08.08)"))
        #expect(after.deliveredAt != nil)
    }

    // MARK: 6. Оптимизатор отвечает на каждый исход

    @Test("нерабочие исходы сокращения не молчат")
    func optimizerSpeaksOnEveryOutcome() {
        #expect(HumanChatModel.optimizerFeedback(.unavailable)?
            .contains("омощник") == true, Comment(rawValue:
            "без помощника кнопка молчала — «оптимизатор не работает» "
            + "(полевой прогон 08.08); строка обязана вести в Настройки"))
        #expect(HumanChatModel.optimizerFeedback(.noGain) != nil)
        #expect(HumanChatModel.optimizerFeedback(
            .rejected("пропало отрицание")) == "пропало отрицание")
        #expect(HumanChatModel.optimizerFeedback(
            .optimized(text: "т", packetsBefore: 2, packetsAfter: 1)) == nil)
    }

    // MARK: 7. Подсказка пустой ленты

    @Test("в чате живого контакта нет слова «Демо-чат»")
    func emptyHintIsHonestForContacts() {
        #expect(HumanChatView.emptyFeedHint(isDemo: true).contains("Демо"))
        #expect(!HumanChatView.emptyFeedHint(isDemo: false).contains("Демо"),
                Comment(rawValue:
                "подсказка демо в чате собеседника убедила владельца, "
                + "что переписка «легла не туда» (полевой прогон 08.08)"))
    }
}

// МЕГА-9 (14.08): keepalive-пульс держит GATT-соединение живым (iOS
// рвала простаивающее каждые ~66 с — пачки и мёртвые окна). Пульс
// обязан быть НЕВИДИМ приёмному тракту: короче 3 байт — ассемблер
// отбрасывает по построению, в onReceive не попадает.
// Слом: сделать кадр пульса ≥3 байт / ослабить guard ассемблера.
nonisolated struct BleKeepaliveTests {

    @Test("пульс keepalive невидим сборке фрагментов")
    func keepaliveIsInvisible() {
        var assembly: [UInt8: (total: Int, chunks: [Int: [UInt8]])] = [:]
        let out = BleLink.assemble(into: &assembly,
                                   fragment: BleLink.keepaliveFrame)
        #expect(out == nil, Comment(rawValue:
                "байт-пульс не смеет собираться в сообщение — он держит "
                + "соединение, не несёт данных (мега-9)"))
        #expect(assembly.isEmpty, "пульс не оставляет следов в сборке")
        #expect(BleLink.keepaliveFrame.count < 3,
                "невидимость держится длиной кадра — guard ассемблера")
        #expect(BleLink.keepaliveFrame.first != WirePadding.marker,
                "пульс не притворяется паддинг-обёрткой №7")
    }
}
