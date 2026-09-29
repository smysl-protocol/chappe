import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Замки блока 1 (спека владельца 10.08): тракт доставки.
//
// Полевой разбор 09.08 (сверка обеих сторон): транспорт залипал на
// мёртвом радио, пузырь перештамповывался («через интернет·10:11» →
// «по радио·10:14»), недоставленное хоронилось при живом интернете.
// Ожидания ниже — из ТЕКСТА спеки владельца, не из кода:
//  1) id и время сообщения неизменны;
//  2) ретрай шлёт то же сообщение;
//  3) ретрай по всем живым путям, радио — последним, без залипания;
//  4) дедуп по id на приёме;
//  5) слово транспорта = путь, ПОДТВЕРДИВШИЙ доставку.
// ============================================================================

struct DeliveryRoutingTests {

    // MARK: Маршрутная матрица (спека п.3)

    @Test("радио — ПОСЛЕДНИМ: при живых быстрых путях эфир молчит")
    func radioGoesLast() {
        let now = Date()
        // радио живо, но жив и релей: радио в этой попытке молчит
        let v1 = DeliveryPolicy.routes(radioAlive: true, relayAlive: true,
                                       nearbyAlive: false,
                                       relayEligible: true,
                                       firstAttemptAt: now, now: now)
        #expect(!v1.radio && v1.relay, Comment(rawValue:
                "приоритет спеки: интернет/рядом первыми, радио "
                + "последним — эфир дорог"))
        // жив сосед «рядом» — тоже быстрые, радио молчит
        let v2 = DeliveryPolicy.routes(radioAlive: true, relayAlive: false,
                                       nearbyAlive: true,
                                       relayEligible: false,
                                       firstAttemptAt: now, now: now)
        #expect(!v2.radio && v2.nearby)
        // быстрых нет — радио идёт сразу
        let v3 = DeliveryPolicy.routes(radioAlive: true, relayAlive: false,
                                       nearbyAlive: false,
                                       relayEligible: false,
                                       firstAttemptAt: nil, now: now)
        #expect(v3.radio, "единственный живой путь не смеет молчать")
    }

    @Test("быстрые буксуют 30 с — радио присоединяется, не раньше")
    func radioJoinsWhenFastStalls() {
        let first = Date(timeIntervalSince1970: 1_000_000)
        // 29-я секунда буксовки: рано
        let early = DeliveryPolicy.routes(
            radioAlive: true, relayAlive: true, nearbyAlive: false,
            relayEligible: true, firstAttemptAt: first,
            now: first.addingTimeInterval(29))
        #expect(!early.radio)
        // 30-я: радио в деле, быстрые продолжают (ретрай по ВСЕМ живым)
        let joined = DeliveryPolicy.routes(
            radioAlive: true, relayAlive: true, nearbyAlive: false,
            relayEligible: true, firstAttemptAt: first,
            now: first.addingTimeInterval(30))
        #expect(joined.radio && joined.relay, Comment(rawValue:
                "спека: недоставленное ретраится по всем живым путям "
                + "до подтверждённой доставки"))
    }

    // МЕГА-6 (14.08): при живом «рядом» релей присоединяется только при
    // буксовке (10 с) — залп обоих путей давал ack-гонку меток
    // «рядом»↔«через интернет» и дубли на релее (вечерний дневник 13.08).
    // Слом: вернуть безусловный relay в авто-ветке routes — красный.
    @Test("«рядом» первым: релей присоединяется по буксовке, не сразу")
    func relayJoinsOnlyWhenNearbyStalls() {
        let first = Date(timeIntervalSince1970: 2_000_000)
        // сосед жив, первая попытка: релей молчит
        let fresh = DeliveryPolicy.routes(
            radioAlive: false, relayAlive: true, nearbyAlive: true,
            relayEligible: true, firstAttemptAt: nil, now: first)
        #expect(fresh.nearby && !fresh.relay, Comment(rawValue:
                "телефоны рядом — сообщение едет «рядом», релей не "
                + "дублирует и метка не прыгает"))
        // 9-я секунда буксовки: рано
        let early = DeliveryPolicy.routes(
            radioAlive: false, relayAlive: true, nearbyAlive: true,
            relayEligible: true, firstAttemptAt: first,
            now: first.addingTimeInterval(9))
        #expect(!early.relay)
        // 10-я: релей в деле, «рядом» продолжает
        let joined = DeliveryPolicy.routes(
            radioAlive: false, relayAlive: true, nearbyAlive: true,
            relayEligible: true, firstAttemptAt: first,
            now: first.addingTimeInterval(10))
        #expect(joined.relay && joined.nearby)
        // соседа нет — релей сразу, как раньше
        let noNearby = DeliveryPolicy.routes(
            radioAlive: false, relayAlive: true, nearbyAlive: false,
            relayEligible: true, firstAttemptAt: nil, now: first)
        #expect(noNearby.relay)
    }

    @Test("мёртвый путь не выбирается — залипания нет (корень 09.08)")
    func deadPathsAreNeverRouted() {
        let now = Date()
        // радио мёртвое (узел вне зоны), интернет жив: только релей —
        // раньше «сконфигурировано» принималось за «живо» и попытки
        // лились в мёртвый линк до похорон сообщения
        let v = DeliveryPolicy.routes(radioAlive: false, relayAlive: true,
                                      nearbyAlive: false,
                                      relayEligible: true,
                                      firstAttemptAt: now, now: now)
        #expect(!v.radio && v.relay)
        // всё мёртвое — попытка не тикает вовсе (похороны не приближаются)
        let dead = DeliveryPolicy.routes(radioAlive: false,
                                         relayAlive: false,
                                         nearbyAlive: false,
                                         relayEligible: true,
                                         firstAttemptAt: now, now: now)
        #expect(!dead.any, Comment(rawValue:
                "нет живых путей — нет попытки: счётчик похорон не "
                + "тикает в никуда"))
        // лежащее в ящике релея повторно не кладётся, но радио может
        // присоединиться по буксовке
        let stored = DeliveryPolicy.routes(
            radioAlive: true, relayAlive: true, nearbyAlive: false,
            relayEligible: false,   // уже в ящике
            firstAttemptAt: now.addingTimeInterval(-60), now: now)
        #expect(stored.radio && !stored.relay)
    }

    // MARK: Штампы пузыря (спека пп.1 и 5) — полевой сценарий 09.08

    @Test("перештамповки нет: релей 10:11, радио 10:14 — пузырь 10:11")
    func noRestampOnSecondPath() {
        var entry = ChatEntry(kind: .outgoing, text: "полевое сообщение")
        let t1011 = Date(timeIntervalSince1970: 1_000_000)
        let t1014 = t1011.addingTimeInterval(180)

        // 10:11 — кадр лёг в ящик релея: sentAt поставлен, пути НЕТ
        DeliveryManager.stampSentOnce(&entry, now: t1011)
        #expect(entry.sentAt == t1011)
        #expect(entry.sentVia == nil, Comment(rawValue:
                "слово пути до подтверждённой доставки запрещено — "
                + "укладка в ящик не есть доставка (спека п.5)"))

        // 10:14 — радио передало пакет узлу: время НЕ двигается
        DeliveryManager.stampSentOnce(&entry, now: t1014)
        #expect(entry.sentAt == t1011, Comment(rawValue:
                "время отправки неизменно (спека п.1): второй путь "
                + "перештамповывал пузырь 10:11 → 10:14 в поле 09.08"))
        #expect(entry.sentVia == nil)

        // ack пришёл по радио — доставку подтвердило радио, путь его
        DeliveryManager.stampDelivered(&entry, via: "radio", now: t1014)
        #expect(entry.sentVia == "radio")
        #expect(entry.deliveredAt == t1014)

        // повторный ack другим путём (дубль через релей) не перекрашивает
        DeliveryManager.stampDelivered(&entry, via: "relay",
                                       now: t1014.addingTimeInterval(9))
        #expect(entry.sentVia == "radio", Comment(rawValue:
                "путь = канал, подтвердивший доставку ПЕРВЫМ; дубль "
                + "ack не перекрашивает"))
        #expect(entry.deliveredAt == t1014)
    }

    @Test("пузырь показывает время нажатия, не время попытки")
    func bubbleTimeIsCreationTime() {
        var entry = ChatEntry(kind: .outgoing, text: "т")
        let created = entry.date
        DeliveryManager.stampSentOnce(
            &entry, now: created.addingTimeInterval(600))
        #expect(entry.stampSent == ChatEntry.hhmm(created), Comment(
                rawValue: "спека п.1: время пузыря = момент нажатия, "
                + "неизменно; sentAt — внутренний статус, не подпись"))
    }

    // MARK: Ручной выбор транспортов (постановка 10.08, блок 2)

    @Test("форс побеждает авто-выбор: в ручном режиме LoRa шлёт сразу")
    func manualModeOverridesAutoPriority() {
        let now = Date()
        // полевой случай 09.08: «слать через радиоустройство» включён,
        // а апп всё равно слал BLE — форс обязан побеждать авто-выбор.
        // В ручном режиме приоритет «радио последним» НЕ применяется:
        let forced = DeliveryPolicy.routes(
            radioAlive: true, relayAlive: true, nearbyAlive: true,
            relayEligible: true, firstAttemptAt: now, now: now,
            manual: true)
        #expect(forced.radio && forced.relay && forced.nearby, Comment(
                rawValue: "человек отметил галочками — шлём всеми "
                + "отмеченными сразу, без очерёдности (спека 10.08)"))
        // авто с теми же входами радио придерживает (контраст)
        let auto = DeliveryPolicy.routes(
            radioAlive: true, relayAlive: true, nearbyAlive: true,
            relayEligible: true, firstAttemptAt: now, now: now,
            manual: false)
        #expect(!auto.radio, "в автомате радио — последним")
    }

    @Test("маска ручного режима: разрешено только отмеченное")
    @MainActor
    func manualMaskGatesTransports() {
        let savedMode = UserDefaults.standard.string(
            forKey: TransportMode.modeKey)
        let savedMask = UserDefaults.standard.stringArray(
            forKey: TransportMode.maskKey)
        defer {
            UserDefaults.standard.set(savedMode, forKey: TransportMode.modeKey)
            UserDefaults.standard.set(savedMask, forKey: TransportMode.maskKey)
        }
        TransportMode.isManual = true
        TransportMode.manualMask = ["lora"]
        #expect(!TransportMode.wifiAllowed && !TransportMode.bleAllowed
                && TransportMode.loraAllowed, Comment(rawValue:
                "галочка LoRa без Wi-Fi/Bluetooth: интернет и «рядом» "
                + "обязаны молчать — человек выбрал руками"))
        TransportMode.isManual = false
        #expect(TransportMode.wifiAllowed && TransportMode.bleAllowed
                && TransportMode.loraAllowed,
                "автомат разрешает всё — выбирает маршрутизация")
    }

    // MARK: Зомби не голодят хвост очереди (стендовый прогон 10.08)

    @Test("слоты такта достаются тем, кому есть чем ехать")
    func staleHeadDoesNotStarveTail() {
        // фикстура — живая очередь со стенда 10.08: в голове зомби
        // (лежит в ящике релея, путей нет), хвост — свежие сообщения;
        // до фикса зомби съедал слот, свежие имели attempts == nil
        // ВЕЧНО («Ничего не пришло.» так и не отправилось)
        func message(_ msgID: UInt16, stored: Bool,
                     relayHex: String?) -> Outbox.QueuedMessage {
            var m = Outbox.QueuedMessage(
                entryID: UUID(), msgID: msgID, packetsHex: ["21000100"],
                totalBytes: 4, contactID: "СТЕНД123")
            if stored { m.relayStoredAt = Date(timeIntervalSinceNow: -600) }
            m.relayStreamHex = relayHex
            return m
        }
        let zombie = message(12758, stored: true, relayHex: "ab")
        let fresh1 = message(10495, stored: false, relayHex: "cd")
        let fresh2 = message(27084, stored: false, relayHex: "ef")
        let queue = [zombie, fresh1, fresh2]
        // живой путь — только релей (радио и «рядом» мертвы)
        func canRoute(_ item: Outbox.QueuedMessage) -> Bool {
            DeliveryPolicy.routes(
                radioAlive: false, relayAlive: true, nearbyAlive: false,
                relayEligible: item.relayStreamHex != nil
                    && item.relayStoredAt == nil && item.relayDone != true,
                firstAttemptAt: item.firstAttemptAt, now: Date()).any
        }
        let picked = DeliveryManager.pickDue(queue: queue, now: Date(),
                                             limit: 2, canRoute: canRoute)
        #expect(picked == [1, 2], Comment(rawValue:
                "зомби в голове (в ящике, путей нет) не смеет съедать "
                + "слот: свежие сообщения обязаны получить оба"))
    }

    // MARK: Дедуп приёма (спека п.4): переотправки не плодят дублей

    @Test("тот же пакет дважды — одна запись в ленте")
    @MainActor
    func duplicateDeliveryIsSuppressed() throws {
        // чужая личность шлёт мне sealed-текст; мультитранспортный
        // ретрай (радио + релей + «рядом») может доставить копии —
        // приёмник обязан погасить их по msgID
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let senderID = Identity.fingerprint(of: sender.publicKey)
        let myPub = try #require(Identity.publicKey())
        defer {
            ContactStore.remove(id: senderID)
            HumanChatStore.saveLog([], contactID: senderID)
        }
        let inner = Array(sender.publicKey.rawRepresentation)
            + [Envelope.codecStore]
            + (try TextCodec.compress("дубль-контроль",
                                      codec: Envelope.codecStore))
        let sealed = try E2ESeal.seal(payload: inner, to: myPub)
        let packet = try #require(try TextEncoder.encodePackets(
            msgID: Envelope.newMsgID(), payload: sealed,
            wantAck: true).first)

        DeliveryManager.shared.ingest(packet)
        DeliveryManager.shared.ingest(packet)   // копия вторым путём
        let log = HumanChatStore.loadLog(contactID: senderID)
        #expect(log.filter { $0.text.contains("дубль-контроль") }.count == 1,
                Comment(rawValue: "спека п.4: дедуп по id — переотправка "
                        + "по второму транспорту не смеет плодить пузыри"))
    }

    // MARK: Непрочитанное (блок 6): точка на чате и бейдж вкладки

    @Test("входящее после открытия чата — непрочитанное; открытие — ноль")
    @MainActor
    func unreadCountsIncomingSinceLastOpen() {
        let id = "UNREAD-\(UUID().uuidString.prefix(8))"
        defer { HumanChatStore.saveLog([], contactID: id) }
        HumanChatStore.markRead(contactID: id)
        #expect(HumanChatStore.unreadCount(contactID: id) == 0)

        var log = HumanChatStore.loadLog(contactID: id)
        log.append(ChatEntry(kind: .incoming, text: "непрочитанное"))
        HumanChatStore.saveLog(log, contactID: id)
        #expect(HumanChatStore.unreadCount(contactID: id) == 1, Comment(
                rawValue: "входящее после последнего открытия чата обязано "
                + "считаться непрочитанным — из него растут точка на чате "
                + "и бейдж вкладки «Чаты» (блок 6)"))

        HumanChatStore.markRead(contactID: id)
        #expect(HumanChatStore.unreadCount(contactID: id) == 0,
                "открытие чата гасит счётчик")
    }

    // Полевой дефект 13.08 («ни уведомления, ни индикатора»): входящее
    // датируется временем ОТПРАВКИ с полом минуты — оно часто РАНЬШЕ
    // последнего открытия чата (пол минуты; задержка релея), и счёт
    // непрочитанного по date молчал. Непрочитанное обязано считаться
    // по моменту ПРИХОДА. Ожидание внешнее: сценарий поля — сообщение,
    // отправленное в 17:09 (пол минуты), пришло в 17:10, чат открывали
    // в 17:09:30 — человек его НЕ видел, счётчик обязан показать 1.
    // Слом: убрать receivedAt из unreadCount — тест краснеет.
    @Test("непрочитанное считается по ПРИХОДУ, не по дате отправки")
    @MainActor
    func unreadCountsByArrivalNotSentTime() {
        let id = "UNREAD-ARR-\(UUID().uuidString.prefix(8))"
        defer { HumanChatStore.saveLog([], contactID: id) }
        HumanChatStore.markRead(contactID: id)   // «открывал в 17:09:30»

        // отправлено «в прошлом» (пол минуты), пришло только что
        var entry = ChatEntry(kind: .incoming, text: "запоздалое",
                              date: Date().addingTimeInterval(-90))
        entry.receivedAt = Date()
        var log = HumanChatStore.loadLog(contactID: id)
        log.append(entry)
        HumanChatStore.saveLog(log, contactID: id)

        #expect(HumanChatStore.unreadCount(contactID: id) == 1, Comment(
                rawValue: "сообщение, ПРИШЕДШЕЕ после открытия чата, обязано "
                + "считаться непрочитанным, даже если ОТПРАВЛЕНО раньше "
                + "(пол минуты/задержка релея) — иначе точка и бейдж молчат"))
    }

    // Та же полевая боль для ПОРЯДКА списка: чат обязан подняться в
    // момент ПРИХОДА сообщения, а не остаться внизу из-за старой даты
    // отправки. Слом: убрать receivedAt из lastActivity — тест краснеет.
    @Test("подъём чата в списке — по ПРИХОДУ последнего сообщения")
    @MainActor
    func lastActivityUsesArrivalTime() {
        let id = "ACT-ARR-\(UUID().uuidString.prefix(8))"
        defer { HumanChatStore.saveLog([], contactID: id) }

        let arrived = Date()
        var entry = ChatEntry(kind: .incoming, text: "запоздалое",
                              date: arrived.addingTimeInterval(-3600))
        entry.receivedAt = arrived
        HumanChatStore.saveLog([entry], contactID: id)

        let activity = HumanChatStore.lastActivity(contactID: id)
        #expect(activity == arrived, Comment(rawValue:
                "активность чата = момент ПРИХОДА: запоздалое на час "
                + "сообщение обязано поднять чат сейчас, не час назад"))
    }

    // Сквозной замок: приёмный тракт (deliver) обязан ШТАМПОВАТЬ приход.
    // Кадр с sentAtMinutes десятиминутной давности, принятый ПОСЛЕ
    // открытия чата, обязан дать счётчик 1. Слом: перестать ставить
    // receivedAt в deliver — оба ожидания краснеют.
    @Test("deliver штампует receivedAt: запоздалый кадр даёт непрочитанное")
    @MainActor
    func deliverStampsArrivalTime() throws {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let senderID = Identity.fingerprint(of: sender.publicKey)
        guard let myPub = Identity.publicKey() else {
            Issue.record("нет своего ключа")
            return
        }
        defer {
            HumanChatStore.saveLog([], contactID: senderID)
            ContactStore.remove(id: senderID)
        }
        HumanChatStore.markRead(contactID: senderID)

        // v1-sealed кадр, отправленный «10 минут назад»
        let sentMinutes = UInt32(Date().timeIntervalSince1970 / 60) - 10
        let inner = Array(sender.publicKey.rawRepresentation)
            + [Envelope.codecStore]
            + (try TextCodec.compress("запоздалый кадр",
                                      codec: Envelope.codecStore))
        let sealed = try E2ESeal.seal(payload: inner, to: myPub)
        let packet = try #require(try TextEncoder.encodePackets(
            msgID: Envelope.newMsgID(), payload: sealed,
            wantAck: false, sentAtMinutes: sentMinutes).first)
        DeliveryManager.shared.ingest(packet)

        let log = HumanChatStore.loadLog(contactID: senderID)
        let entry = log.first { $0.text.contains("запоздалый кадр") }
        #expect(entry?.receivedAt != nil, Comment(rawValue:
                "deliver обязан штамповать момент прихода — на нём стоят "
                + "непрочитанное и подъём чата"))
        #expect(HumanChatStore.unreadCount(contactID: senderID) == 1,
                Comment(rawValue: "запоздалый кадр, пришедший после "
                + "открытия чата, обязан считаться непрочитанным"))
    }

    // MARK: Поле 13.08, build 19 — блок P0

    // п.5: пачка сообщений к сброшенной личности (ack не родится)
    // ретраилась каждые 60 с и съедала оба слота такта — свежее ждало
    // 30+ с. Свежие (меньше попыток) обязаны выбираться первыми.
    // Слом: вернуть выбор по порядку очереди — тест краснеет.
    @Test("свежие сообщения берут слоты насоса раньше долгих ретраев")
    func freshMessagesBeatZombieRetries() {
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ msgID: UInt16, attempts: Int?) -> Outbox.QueuedMessage {
            var q = Outbox.QueuedMessage(entryID: UUID(), msgID: msgID,
                                         packetsHex: ["00"], totalBytes: 1,
                                         contactID: "c")
            q.attempts = attempts
            q.lastAttemptAt = attempts != nil ? past : nil
            return q
        }
        // зомби в голове очереди (по 10 попыток), свежее — в хвосте
        let queue = [item(1, attempts: 10), item(2, attempts: 10),
                     item(3, attempts: 10), item(4, attempts: nil)]
        let picked = DeliveryManager.pickDue(queue: queue, now: Date(),
                                             limit: 2)
        #expect(picked.first == 3, Comment(rawValue:
                "свежее сообщение (0 попыток) обязано взять слот раньше "
                + "зомби-ретраев — иначе «первое долго не шло» (поле 13.08)"))
        #expect(picked.count == 2 && picked[1] == 0,
                "второй слот — старейший из зомби, порядок очереди цел")
    }

    // п.2: снятая галка «Рядом»/«Радио» обязана глушить и СЛУЖЕБНЫЕ
    // пакеты (ack/квитанции) — раньше маска резала только насос, и
    // сообщения «летели как рядом» вопреки тумблеру.
    @Test("маска транспортов глушит служебные каналы (ack/квитанции)")
    func serviceChannelsHonorManualMask() {
        let both = DeliveryManager.serviceChannels(
            radioReady: true, nearbyReady: true, relayReady: true,
            loraAllowed: true, bleAllowed: true)
        #expect(both.radio && both.nearby && both.relay)

        let bleOff = DeliveryManager.serviceChannels(
            radioReady: true, nearbyReady: true, relayReady: true,
            loraAllowed: true, bleAllowed: false)
        #expect(bleOff.radio && !bleOff.nearby, Comment(rawValue:
                "снятая галка «Рядом» обязана глушить BLE и для ack — "
                + "иначе тумблер «не работает» на ощупь (поле 13.08)"))

        let loraOff = DeliveryManager.serviceChannels(
            radioReady: true, nearbyReady: true, relayReady: true,
            loraAllowed: false, bleAllowed: true)
        #expect(!loraOff.radio && loraOff.nearby)

        // Поле 29.09: в форс-«только интернет» ack ОБЯЗАН уметь релей —
        // иначе доставленное вечно висит «ждём собеседника» (relayReady
        // уже включает разрешение галки wifi через active)
        let relayOnly = DeliveryManager.serviceChannels(
            radioReady: false, nearbyReady: false, relayReady: true,
            loraAllowed: false, bleAllowed: false)
        #expect(relayOnly.relay && !relayOnly.radio && !relayOnly.nearby,
                Comment(rawValue: "подтверждение доставки обязано ходить "
                + "релеем, когда это единственный живой путь"))
        let relayDead = DeliveryManager.serviceChannels(
            radioReady: true, nearbyReady: true, relayReady: false,
            loraAllowed: true, bleAllowed: true)
        #expect(!relayDead.relay, "мёртвый релей ack не получает")
    }

    // п.3(1): «прочитано» на ПРИХОД при спящем телефоне — чат, забытый
    // открытым, квитировал входящие мгновенно. Квитанция рождается
    // ТОЛЬКО у активного приложения. Слом: убрать guard appActive.
    @Test("неактивное приложение не рождает квитанций прочтения")
    @MainActor
    func inactiveAppSendsNoReadReceipts() {
        let cid = "чтение-неактив-1308"
        var entry = ChatEntry(kind: .incoming, text: "спящий приём")
        entry.wireMsgID = 51515
        HumanChatStore.saveLog([entry], contactID: cid)
        defer { HumanChatStore.saveLog([], contactID: cid) }

        nonisolated(unsafe) var sent = 0
        DeliveryManager.shared.sendReadReceipts(
            contactID: cid, appActive: false) { _, done in
            sent += 1
            done(true)
        }
        #expect(sent == 0, Comment(rawValue:
                "приёмник спит — «прочитано» рождаться не смеет: "
                + "отправитель видел зелёное при спящем человеке (поле 13.08)"))
        #expect(HumanChatStore.loadLog(contactID: cid).first?.readAt == nil)
    }

    // п.4: потерянная квитанция ждала следующего ОТКРЫТИЯ чата —
    // «жёлтый не снимается». Насос обязан дослать должникам.
    // Слом: убрать retryReadReceipts из тика насоса / реестр должников.
    @Test("потерянная квитанция досылается насосом, не ждёт открытия чата")
    @MainActor
    func lostReceiptRetriedByPump() async throws {
        let cid = "квитанция-ретрай-1308"
        var entry = ChatEntry(kind: .incoming, text: "первый заход")
        entry.wireMsgID = 52525
        HumanChatStore.saveLog([entry], contactID: cid)
        defer { HumanChatStore.saveLog([], contactID: cid) }
        let dm = DeliveryManager.shared

        // открытие чата: канал ПРОВАЛИЛ отправку — штампа нет
        dm.sendReadReceipts(contactID: cid, appActive: true) { _, done in
            done(false)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(HumanChatStore.loadLog(contactID: cid).first?.readAt == nil,
                "проваленная отправка не штампует")

        // тик насоса: канал ожил — квитанция досылается БЕЗ открытия
        // чата; only — чтобы override не доштамповал должников
        // параллельных тестов (общий реестр, поймано сюитой 14.08)
        dm.retryReadReceipts(only: cid) { _, done in done(true) }
        try await until("квитанция дослана насосом") {
            HumanChatStore.loadLog(contactID: cid).first?.readAt != nil
        }
    }

    // п.7: у входящих не было метки транспорта вовсе. Приёмный тракт
    // обязан штамповать канал прихода. Слом: убрать receivedVia из
    // deliver — тест краснеет.
    @Test("входящее несёт канал прихода (receivedVia)")
    @MainActor
    func incomingCarriesTransportLabel() throws {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let senderID = Identity.fingerprint(of: sender.publicKey)
        guard let myPub = Identity.publicKey() else {
            Issue.record("нет своего ключа")
            return
        }
        defer {
            HumanChatStore.saveLog([], contactID: senderID)
            ContactStore.remove(id: senderID)
        }
        let inner = Array(sender.publicKey.rawRepresentation)
            + [Envelope.codecStore]
            + (try TextCodec.compress("метка канала",
                                      codec: Envelope.codecStore))
        let sealed = try E2ESeal.seal(payload: inner, to: myPub)
        let packet = try #require(try TextEncoder.encodePackets(
            msgID: Envelope.newMsgID(), payload: sealed).first)
        DeliveryManager.shared.ingest(packet)   // ingest = канал «relay»

        let entry = HumanChatStore.loadLog(contactID: senderID)
            .first { $0.text.contains("метка канала") }
        #expect(entry?.receivedVia == "relay", Comment(rawValue:
                "канал прихода обязан штамповаться на каждом входящем — "
                + "метка транспорта была пустой у большинства (поле 13.08)"))
        #expect(entry?.incomingTimeLine.hasPrefix("через интернет") == true,
                "строка входящего начинается со слова канала")
    }

    // MARK: Геотрансляция (блок 5): остаток времени — человеку

    @Test("остаток гранта: часы, минуты, меньше минуты — литералы руками")
    func grantRemainingTextByHand() {
        #expect(LocationShareIndicator.remainingText(3 * 3600 + 12 * 60)
                == "3 ч 12 мин")
        #expect(LocationShareIndicator.remainingText(45 * 60) == "45 мин")
        #expect(LocationShareIndicator.remainingText(30) == "меньше минуты")
        #expect(LocationShareIndicator.remainingText(4 * 3600) == "4 ч 0 мин",
                Comment(rawValue: "«делюсь 4 часа» сразу после включения"))
    }

    // MARK: Порядок ленты = порядок ОТПРАВКИ (полевой прогон 10.08)

    @Test("залповая разгрузка не ломает порядок: лента по времени отправки")
    @MainActor
    func burstDeliveryKeepsSendOrder() throws {
        // поле 10.08: свёрнутый приёмник разгрузил копилку разом —
        // «500м, 350м, 750м и последним 700м»; лента строилась по
        // времени ПРИХОДА. Пакеты несут минуты отправки — они и
        // задают порядок
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let senderID = Identity.fingerprint(of: sender.publicKey)
        let myPub = try #require(Identity.publicKey())
        defer {
            ContactStore.remove(id: senderID)
            HumanChatStore.saveLog([], contactID: senderID)
        }
        func packet(_ text: String, minutes: UInt32) throws -> [UInt8] {
            let inner = Array(sender.publicKey.rawRepresentation)
                + [Envelope.codecStore]
                + (try TextCodec.compress(text, codec: Envelope.codecStore))
            let sealed = try E2ESeal.seal(payload: inner, to: myPub)
            return try #require(try TextEncoder.encodePackets(
                msgID: Envelope.newMsgID(), payload: sealed,
                wantAck: false, sentAtMinutes: minutes).first)
        }
        let early = UInt32(Date().timeIntervalSince1970 / 60) - 30
        // приход в ОБРАТНОМ порядке отправки (залп из копилки)
        DeliveryManager.shared.ingest(try packet("отправлено-вторым",
                                                 minutes: early + 10))
        DeliveryManager.shared.ingest(try packet("отправлено-первым",
                                                 minutes: early))
        let log = HumanChatStore.loadLog(contactID: senderID)
            .sorted { $0.date < $1.date }
        let первым = try #require(log.firstIndex {
            $0.text.contains("отправлено-первым") })
        let вторым = try #require(log.firstIndex {
            $0.text.contains("отправлено-вторым") })
        #expect(первым < вторым, Comment(rawValue:
                "лента обязана строиться по времени ОТПРАВКИ из пакета, "
                + "не по порядку прихода (поле 10.08: 500/350/750/700)"))

        // залп ОДНОЙ минуты: метка минутная, но порядок прихода
        // внутри минуты обязан сохраниться (тай-брейк +1 мс)
        DeliveryManager.shared.ingest(try packet("той-же-минуты-после",
                                                 minutes: early))
        let log2 = HumanChatStore.loadLog(contactID: senderID)
            .sorted { $0.date < $1.date }
        let a = try #require(log2.firstIndex {
            $0.text.contains("отправлено-первым") })
        let b = try #require(log2.firstIndex {
            $0.text.contains("той-же-минуты-после") })
        #expect(a < b, Comment(rawValue:
                "внутри одной минуты порядок прихода не смеет "
                + "перевернуться — тай-брейк держит залп"))
    }

    // Полевой своп 12.08: мой ВОПРОС (исходящее, реальное локальное
    // время 17:09:10) и ОТВЕТ собеседника (входящее, метка минуты
    // 17:09:00) — одна минута. Тай-брейк, смотревший только incoming,
    // ставил ответ ВЫШЕ моего вопроса («странно, я послал раньше, а
    // твоё сообщение выше»). Ответ обязан встать ПОСЛЕ вопроса.
    @Test("ответ собеседника той же минуты — НИЖЕ моего вопроса, не выше")
    @MainActor
    func replySortsBelowMyQuestionSameMinute() throws {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let senderID = Identity.fingerprint(of: sender.publicKey)
        let myPub = try #require(Identity.publicKey())
        defer {
            ContactStore.remove(id: senderID)
            HumanChatStore.saveLog([], contactID: senderID)
        }
        let minute = UInt32(Date().timeIntervalSince1970 / 60) - 20
        // мой вопрос — исходящее с реальным временем +10 с внутри минуты
        let question = ChatEntry(
            kind: .outgoing, text: "мой-вопрос",
            date: Date(timeIntervalSince1970: TimeInterval(minute) * 60 + 10))
        HumanChatStore.upsertLog(question, contactID: senderID)
        // ответ собеседника — входящее той же минуты (метка = пол минуты)
        let inner = Array(sender.publicKey.rawRepresentation)
            + [Envelope.codecStore]
            + (try TextCodec.compress("ответ-собеседника",
                                      codec: Envelope.codecStore))
        let sealed = try E2ESeal.seal(payload: inner, to: myPub)
        let packet = try #require(try TextEncoder.encodePackets(
            msgID: Envelope.newMsgID(), payload: sealed,
            wantAck: false, sentAtMinutes: minute).first)
        DeliveryManager.shared.ingest(packet)

        let log = HumanChatStore.loadLog(contactID: senderID)
            .sorted { $0.date < $1.date }
        let q = try #require(log.firstIndex { $0.text.contains("мой-вопрос") })
        let r = try #require(log.firstIndex {
            $0.text.contains("ответ-собеседника") })
        #expect(q < r, Comment(rawValue:
                "ответ той же минуты обязан встать ПОСЛЕ моего вопроса — "
                + "тай-брейк учитывает записи любого вида, не только входящие"))
    }

    // MARK: Мёртвый линк узла отвечает отказом сразу (не молчанием)

    @Test("send в мёртвый MeshtasticLink — немедленный false",
          .timeLimit(.minutes(1)))
    func deadMeshLinkFailsFast() async {
        // линк не стартовал: узла нет, isLinkUp == false. Раньше пакет
        // ложился в waiting, completion висел молча, а насос тикал
        // попытки — правило 3: тишина не есть отказ
        let link = MeshtasticLink()
        #expect(!link.isLinkUp)
        let outcome = await withCheckedContinuation { cont in
            link.send([0x21, 0x00, 0x01, 0x00], toHost: "") {
                cont.resume(returning: $0)
            }
        }
        #expect(outcome == false, Comment(rawValue:
                "мёртвый линк обязан отказать сразу: висящий completion "
                + "маскировал мёртвое радио под «отправляется»"))
    }
}

// ============================================================================
// МЕГА-8 (14.08): зомби-ретраи к сброшенной личности — ограниченный
// ретрай и честный статус, не вечный молчаливый повтор.
// Слом: убрать confirmedSends-ветку из buryVerdict — красный.
// ============================================================================

nonisolated struct ZombieBurialTests {

    @Test("K подтверждённых передач без ack — честные похороны")
    func confirmedSendsWithoutAckBuries() {
        let now = Date()
        let verdict = DeliveryManager.buryVerdict(
            attempts: 12, confirmedSends: 10, expectsAck: true,
            relayStoredAt: nil, relayDone: nil, now: now)
        #expect(verdict?.contains("сбросил приложение") == true, Comment(
                rawValue: "адресат принимает байты, но не отвечает — "
                + "человек обязан узнать причину, а не смотреть на вечный "
                + "повтор (вечер 13.08: 5 зомби × 60 с)"))
        // девять подтверждений — ещё живём
        #expect(DeliveryManager.buryVerdict(
            attempts: 12, confirmedSends: 9, expectsAck: true,
            relayStoredAt: nil, relayDone: nil, now: now) == nil)
        // маячок без ack под этот вердикт не попадает
        #expect(DeliveryManager.buryVerdict(
            attempts: 12, confirmedSends: 30, expectsAck: false,
            relayStoredAt: nil, relayDone: nil, now: now) == nil,
            "без ожидания ack подтверждения — не признак сброса")
    }

    @Test("прежние основания похорон живы: потолок попыток и ящик 48 ч")
    func legacyBurialGroundsIntact() {
        let now = Date()
        #expect(DeliveryManager.buryVerdict(
            attempts: DeliveryManager.maxAttempts, confirmedSends: 0,
            expectsAck: true, relayStoredAt: nil, relayDone: nil,
            now: now)?.contains("попыток исчерпаны") == true)
        #expect(DeliveryManager.buryVerdict(
            attempts: 3, confirmedSends: 0, expectsAck: true,
            relayStoredAt: now.addingTimeInterval(-49 * 3600),
            relayDone: nil, now: now)?.contains("не забрал за 48 ч") == true)
        #expect(DeliveryManager.buryVerdict(
            attempts: 3, confirmedSends: 0, expectsAck: true,
            relayStoredAt: nil, relayDone: nil, now: now) == nil,
            "свежее сообщение живёт")
    }
}

// ============================================================================
// Бэкофф-фикс 14.08 (данные владельца: nearby-чат ~5 мин, сообщение
// ~2 мин, квант 60–67 с): промах BLE-окна ждал хвост бэкоффа,
// синхронизированного с периодом флапа. Появление соседа обнуляет
// бэкофф — отправка в первое же окно. Слом: убрать сброс из
// resetBackoffForNearbyWindow / вызов из onPeersChanged — красный.
// ============================================================================

nonisolated struct NearbyWindowBackoffTests {

    private func item(_ msgID: UInt16, attempts: Int?,
                      lastAttempt: Date?, relayStored: Date? = nil)
    -> Outbox.QueuedMessage {
        var q = Outbox.QueuedMessage(entryID: UUID(), msgID: msgID,
                                     packetsHex: ["00"], totalBytes: 1,
                                     contactID: "c")
        q.attempts = attempts
        q.lastAttemptAt = lastAttempt
        q.relayStoredAt = relayStored
        return q
    }

    @Test("появление соседа обнуляет бэкофф ретраев, ящик релея не трогая")
    func windowResetsBackoff() {
        let recent = Date()
        var queue = [
            item(1, attempts: 3, lastAttempt: recent),              // ждал хвост
            item(2, attempts: nil, lastAttempt: nil),               // свежее
            item(3, attempts: 5, lastAttempt: recent,
                 relayStored: recent),                              // в ящике
        ]
        let touched = DeliveryManager.resetBackoffForNearbyWindow(&queue)
        #expect(touched == 1, "сбрасывается только ждущий ретраев")
        #expect(queue[0].lastAttemptAt == nil, Comment(rawValue:
                "промах окна не смеет ждать до 60 с — сосед появился, "
                + "шлём сразу (квантование 60–67 с, 14.08)"))
        #expect(DeliveryManager.isDue(queue[0], now: Date()),
                "после сброса запись немедленно due для насоса")
        #expect(queue[2].lastAttemptAt != nil,
                "лежащее в ящике релея окно «рядом» не трогает")
    }
}


// ============================================================================
// P0 поле 14.08: релей при обоих онлайн вёз 30 с–минуты. Дневник
// (телефон 1): укладка в ящик 20:59:28 → «получатель забрал» 20:59:42,
// разрыв 14 с = плоский опрос раз в 12 с + опрос исходов тем же тактом.
// Форграунд обязан опрашивать СЕКУНДАМИ; фон — прежние 12 с (APNs
// позже). Слом: вернуть плоские 12 с в pollInterval — красный.
// ============================================================================

nonisolated struct RelayForegroundPollTests {

    @Test("опрос релея: форграунд — секунды, фон — прежний такт")
    func foregroundPollsInSeconds() {
        #expect(RelayTransport.pollInterval(appActive: true)
                <= .seconds(3), Comment(rawValue:
                "активное приложение обязано забирать ящик за секунды — "
                + "12-секундный такт давал 10–25 с на доставку (поле 14.08)"))
        #expect(RelayTransport.pollInterval(appActive: false)
                == .seconds(12),
                "фон не учащается — фоновая политика отдельно (APNs)")
    }
}
