import Foundation
import Combine
import CryptoKit
import UIKit

// ============================================================================
// DeliveryManager (веха, фаза 3; transport_manager.md §1):
// очередь Outbox → активный транспорт → ack → статусы
// «отправлено/доставлено HH:MM», «узлов: N» — по-настоящему.
//
// Отправка контакту: payload = sealed box (внутри —
// [pubkey отправителя 32][кодек][данные], получатель по нему находит
// чат). Приём: сборка фрагментов → расшифровка своим ключом →
// развёртка → входящий пузырь + ack отправителю.
// ============================================================================

@MainActor
final class DeliveryManager: ObservableObject {

    static let shared = DeliveryManager()

    @Published var transportKind: String {
        didSet {
            UserDefaults.standard.set(transportKind, forKey: "transport_kind")
            restart()
        }
    }
    @Published var peerHost: String {
        didSet {
            UserDefaults.standard.set(peerHost, forKey: "transport_peer")
            nodeCount = (transportKind == "lan" && !peerHost.isEmpty) ? 1 : 0
        }
    }
    /// Счётчик живых узлов (для вехи: 1, если lan и peer задан).
    @Published private(set) var nodeCount = 0
    /// Меняется на каждый принятый пакет — UI перечитывает ленты.
    @Published private(set) var eventCounter = 0
    /// Тревога детектора клина (03.08): узел копит пакеты и не отдаёт /
    /// не отвечает. nil — тревоги нет. Чат показывает баннером.
    @Published private(set) var linkWarning: String?

    private var link: TransportLink = DemoLoopback()
    /// Сборка фрагментов: msgID → (total, [index: chunk])
    private var pending: [UInt16: (total: Int, chunks: [Int: [UInt8]])] = [:]
    /// Насос повторов: раз в 2 с проверяет, не пора ли дослать.
    private var retryPump: Task<Void, Never>?
    /// Текущий пакет пришёл прямым путём «рядом» (см. NearbyPresence).
    private var receivingFromNearby = false

    private init() {
        var kind = UserDefaults.standard.string(forKey: "transport_kind")
            ?? "demo"
        // фаза 1 «рядом» (07.08): прямой BLE больше не вид транспорта,
        // а всегда-параллельный путь NearbyTransport; сохранённый "ble"
        // тихо превращается в "demo", ничего не теряя
        if kind == "ble" { kind = "demo" }
        transportKind = kind
        peerHost = UserDefaults.standard.string(forKey: "transport_peer") ?? ""
        restart()
        NearbyTransport.shared.onReceive = { [weak self] packet in
            Task { @MainActor in
                // пакет пришёл прямым путём: отметка «этот контакт
                // рядом» ставится ниже, при опознании отправителя
                self?.receivingFromNearby = true
                self?.handle(packet, via: "nearby")
                self?.receivingFromNearby = false
            }
        }
        retryPump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.pushQueue()
                self?.flushAcks()
                self?.retryReadReceipts()   // должники квитанций (13.08)
            }
        }
    }

    /// Смена/подключение радиоустройства (просьба владельца 10.08):
    /// имя-фильтр узла — настройкой (сильнее бандл-конфига, как
    /// заведено), линк пересоздаётся и сам находит узел сканом.
    /// Выбор устройства ВКЛЮЧАЕТ радио-транспорт — отдельного тумблера
    /// больше нет (экран «Радиоустройства (LoRa)» только про устройства).
    func switchRadioDevice(named name: String) {
        UserDefaults.standard.set(name, forKey: "mesh_peripheral_name")
        TransportDiary.note("[радио] смена устройства: \(name)")
        guard transportKind == "mesh" else {
            transportKind = "mesh"   // didSet сам пересоздаст линк
            return
        }
        link.stop()
        let mesh = MeshtasticLink()
        mesh.onReceive = { [weak self] packet in
            Task { @MainActor in self?.handle(packet, via: "radio") }
        }
        mesh.onLinkWarning = { [weak self] warning in
            Task { @MainActor in self?.showLinkWarning(warning) }
        }
        mesh.start()
        link = mesh
    }

    func restart() {
        // смена peer не требует пересоздания listener; пересоздаём
        // только при смене вида транспорта (порт освобождается не сразу)
        if transportKind == "lan", link is LanLink {
            nodeCount = peerHost.isEmpty ? 0 : 1
            return
        }
        if transportKind == "mesh", link is MeshtasticLink { return }
        link.stop()
        switch transportKind {
        case "mesh":
            // радио принадлежит транспорту: диагностика обязана
            // отпустить узел, иначе он не рекламируется и mesh-линк
            // не найдёт его сканом (02.08, живой радиотест)
            NodeProbe.shared.yieldRadio()
            let mesh = MeshtasticLink()
            mesh.onReceive = { [weak self] packet in
                Task { @MainActor in self?.handle(packet, via: "radio") }
            }
            mesh.onLinkWarning = { [weak self] warning in
                Task { @MainActor in self?.showLinkWarning(warning) }
            }
            mesh.start()
            link = mesh
            nodeCount = 1
        case "lan":
            let lan = LanLink()
            lan.onReceive = { [weak self] packet in
                Task { @MainActor in self?.handle(packet, via: "lan") }
            }
            lan.start()
            link = lan
            nodeCount = peerHost.isEmpty ? 0 : 1
        default:
            link = DemoLoopback()
            nodeCount = 0
        }
    }

    // MARK: Отправка

    /// Прогнать очередь: адресные сообщения, чей срок повтора настал, —
    /// в канал. «Отправлено» — только по факту успешной передачи;
    /// повторы идут до ack (получатель отбрасывает дубли по msgID).
    var meshLink: MeshtasticLink? { link as? MeshtasticLink }

    /// Дозирование (замок на клин, 03.08): за один проход насоса в канал
    /// уходит не больше sendsPerPass сообщений. Насос тикает каждые 2 с,
    /// так что залпа «весь outbox разом при запуске» больше нет — он
    /// глушил приёмник узла и клинил PhoneAPI.
    static let sendsPerPass = 2

    /// Чистый выбор готовых к отправке: индексы первых limit сообщений,
    /// чей срок повтора настал И которым есть чем ехать (`canRoute`).
    ///
    /// canRoute — стендовый прогон 10.08: запись, которой нет пути
    /// (лежит в ящике релея при мёртвом радио), выбиралась в слот и
    /// съедала его вхолостую — зомби в голове очереди голодили хвост:
    /// живые сообщения не отправлялись НИКОГДА (attempts nil у свежих
    /// записей при 1291 попытке у зомби 07.08).
    ///
    /// СВЕЖИЕ — ПЕРВЫМИ (поле 13.08, build 19): пачка из 5 сообщений
    /// к сброшенной личности (расшифровать некому, ack не родится)
    /// ретраилась каждые 60 с и съедала оба слота такта — свежее
    /// сообщение ждало 30+ с («первое долго не шло, потом пробило»).
    /// Кандидаты сортируются по числу попыток (меньше — раньше),
    /// внутри равных — порядок очереди.
    nonisolated static func pickDue(queue: [Outbox.QueuedMessage],
                                    now: Date, limit: Int,
                                    canRoute: (Outbox.QueuedMessage) -> Bool
                                        = { _ in true }) -> [Int] {
        var candidates: [Int] = []
        for index in queue.indices
        where queue[index].contactID != nil && isDue(queue[index], now: now)
            && canRoute(queue[index]) {
            candidates.append(index)
        }
        let ordered = candidates.sorted {
            let a = queue[$0].attempts ?? 0
            let b = queue[$1].attempts ?? 0
            return a != b ? a < b : $0 < $1
        }
        return Array(ordered.prefix(limit))
    }

    /// Мега-8 (14.08): K подтверждённых передач БЕЗ ack = адресат
    /// принимает байты, но не отвечает — типовой случай «собеседник
    /// сбросил личность» (вечер 13.08: пачка из 5 зомби ретраилась
    /// каждые 60 с к нерасшифровываемому ключу). Дальше ретраить —
    /// жечь эфир впустую; честный статус вместо молчания.
    static let confirmedSendsCeiling = 10

    /// Чистый вердикт похорон записи очереди: строка статуса или nil
    /// (жить). Порядок проверок — от самого содержательного основания.
    nonisolated static func buryVerdict(attempts: Int?, confirmedSends: Int?,
                                        expectsAck: Bool,
                                        relayStoredAt: Date?,
                                        relayDone: Bool?,
                                        now: Date) -> String? {
        if expectsAck, (confirmedSends ?? 0) >= confirmedSendsCeiling {
            return "не доставлено: собеседник получает, но не отвечает — "
                 + "возможно, он сбросил приложение. Познакомьтесь заново "
                 + "или сверьтесь по QR"
        }
        if let storedAt = relayStoredAt, relayDone != true,
           now.timeIntervalSince(storedAt) > 48 * 3600 {
            return "не доставлено: получатель не забрал за 48 ч"
        }
        if relayStoredAt == nil, (attempts ?? 0) >= maxAttempts {
            return "не дошло: \(maxAttempts) попыток исчерпаны — "
                 + "отправьте заново, когда появится связь"
        }
        return nil
    }

    /// Потолок повторов (WP3, 05.08). Раньше повторы были вечными —
    /// полевые логи видели 890 и 1149 попыток: часы эфира и вечное
    /// «отправляется» вместо честного отказа. По счётчику — страховка
    /// для путей без кода отказа (радио); релейный путь получает
    /// «сдаюсь» с ОСНОВАНИЕМ раньше (410 надгробие).
    static let maxAttempts = 50

    /// Радио сконфигурировано и способно слать.
    var radioReady: Bool {
        transportKind == "mesh"
            || (transportKind == "lan" && !peerHost.isEmpty)
    }

    /// Радио ЖИВО прямо сейчас — для маршрутизации (блок 1, 10.08).
    /// «Сконфигурировано» ≠ «живо»: полевая потеря 09.08 — узел вне
    /// зоны, а насос лил попытки в мёртвый линк до похорон сообщения.
    var radioAlive: Bool {
        if transportKind == "mesh" { return meshLink?.isLinkUp == true }
        return radioReady   // lan — dev-транспорт без пульса живости
    }

    /// Прямой путь «рядом» существует прямо сейчас (есть живые соседи).
    var nearbyReady: Bool { NearbyTransport.shared.peerCount > 0 }

    func pushQueue() {
        // режим транспортов (10.08): вручную живут только отмеченные
        let manual = TransportMode.isManual
        let relayReady = RelayTransport.shared.active
            && TransportMode.wifiAllowed
        let nearbyReady = self.nearbyReady && TransportMode.bleAllowed
        let radioAlive = self.radioAlive && TransportMode.loraAllowed
        // решение по ЖИВЫМ путям, не по сконфигурированным: попытки в
        // мёртвый линк не тикают и не хоронят сообщение (блок 1, 10.08)
        guard radioAlive || relayReady || nearbyReady else { return }
        let now = Date()
        var queue = Outbox.loadQueueRaw()

        // похороны — единым чистым вердиктом (мега-8): потолок попыток,
        // непозабранный ящик 48 ч, K подтверждённых передач без ack
        // («собеседник сбросился» — честный статус вместо вечного
        // молчаливого повтора)
        var buried: [(item: Outbox.QueuedMessage, status: String)] = []
        queue.removeAll { item in
            guard item.contactID != nil,
                  let status = Self.buryVerdict(
                    attempts: item.attempts,
                    confirmedSends: item.confirmedSends,
                    expectsAck: item.expectsAck,
                    relayStoredAt: item.relayStoredAt,
                    relayDone: item.relayDone, now: now) else { return false }
            buried.append((item, status))
            return true
        }
        for (item, status) in buried {
            markEntry(entryID: item.entryID, contactID: item.contactID) { entry in
                guard entry.deliveredAt == nil else { return }
                entry.status = status
            }
            TransportDiary.note("[насос] похоронено: \(status)")
            eventCounter += 1
        }

        // маршрутный вердикт считается ДО занятия слота (canRoute):
        // иначе запись без живого пути съедает слот такта вхолостую
        // и живые за ней голодают (стендовый прогон 10.08)
        func verdict(for item: Outbox.QueuedMessage) -> DeliveryPolicy.Verdict {
            DeliveryPolicy.routes(
                radioAlive: radioAlive, relayAlive: relayReady,
                nearbyAlive: nearbyReady,
                relayEligible: item.relayStreamHex != nil
                    && item.relayStoredAt == nil && item.relayDone != true,
                firstAttemptAt: item.firstAttemptAt, now: now,
                manual: manual)
        }

        var due: [(item: Outbox.QueuedMessage, radio: Bool, relay: Bool,
                   nearby: Bool)] = []
        for index in Self.pickDue(queue: queue, now: now,
                                  limit: Self.sendsPerPass,
                                  canRoute: { verdict(for: $0).any }) {
            let item = queue[index]
            // лежащее в ящике повторно не кладём: дедуп релея это
            // стерпел бы, но попытки не должны тикать впустую.
            // «Рядом» — параллельно прочим путям: дубль на приёме
            // отбрасывает дедуп (SeenMsgIDs + счётчик рэтчета).
            // Радио — последним (спека блока 1): решает DeliveryPolicy.
            let verdict = verdict(for: item)
            guard verdict.any else { continue }
            queue[index].attempts = (queue[index].attempts ?? 0) + 1
            queue[index].lastAttemptAt = now
            if queue[index].firstAttemptAt == nil {
                queue[index].firstAttemptAt = now
            }
            due.append((queue[index], verdict.radio, verdict.relay,
                        verdict.nearby))
        }
        if !due.isEmpty || !buried.isEmpty {
            Outbox.saveQueueRaw(queue)
        }
        for entry in due {
            if entry.radio { sendPackets(entry.item) }
            if entry.relay { RelayTransport.shared.send(entry.item) }
            if entry.nearby { sendNearby(entry.item) }
        }
    }

    /// Окно «рядом» открылось (реконнект BLE): бэкофф обнуляется и
    /// очередь толкается НЕМЕДЛЕННО (корень квантования 60–67 с,
    /// данные владельца 14.08: чат ~5 мин, сообщение ~2 мин — промах
    /// окна ждал хвост бэкоффа, синхронизированного с периодом флапа).
    /// Чистый сброс — под замком; релейно-лежащие не трогаются.
    nonisolated static func resetBackoffForNearbyWindow(
        _ queue: inout [Outbox.QueuedMessage]) -> Int {
        var touched = 0
        for index in queue.indices
        where queue[index].contactID != nil
            && queue[index].relayStoredAt == nil
            && (queue[index].attempts ?? 0) > 0 {
            queue[index].lastAttemptAt = nil
            touched += 1
        }
        return touched
    }

    /// Вызывается транспортом «рядом» при появлении соседа.
    func nearbyWindowOpened() {
        var touched = 0
        Outbox.mutateQueue { queue in
            touched = Self.resetBackoffForNearbyWindow(&queue)
        }
        if touched > 0 {
            TransportDiary.note("[насос] окно «рядом» открылось — "
                + "бэкофф сброшен у \(touched), шлю сразу")
            pushQueue()
        }
        // квитанции-должники тоже не ждут тика
        retryReadReceipts()
    }

    /// Пора ли повторить: первая попытка — сразу, дальше по бэкоффу.
    /// Сообщение, уже лежащее в ящике релея, повторов не требует —
    /// если радио не сконфигурировано, слать его больше некуда, а
    /// судьбу решает наблюдение ящика (RelayTransport).
    nonisolated static func isDue(_ item: Outbox.QueuedMessage,
                                  now: Date) -> Bool {
        guard let attempts = item.attempts, attempts > 0,
              let last = item.lastAttemptAt else { return true }
        return now.timeIntervalSince(last)
            >= retryDelay(afterAttempts: attempts)
    }

    /// Пауза перед повтором: 4с → 8с → 16с → 32с → потолок 60с.
    nonisolated static func retryDelay(afterAttempts attempts: Int)
    -> TimeInterval {
        min(60, pow(2, Double(min(attempts, 5))) * 2)
    }

    /// Все пакеты сообщения — в канал; итог попытки — одним словом.
    private func sendPackets(_ item: Outbox.QueuedMessage) {
        let via = transportKind == "mesh" ? "radio" : "lan"
        let packets = item.packetsHex.map(Outbox.bytes(fromHex:))
        let tally = SendTally(total: packets.count) { [weak self] allOK in
            Task { @MainActor in
                self?.attemptFinished(item, success: allOK, via: via)
            }
        }
        for packet in packets {
            // №7: lan паддится в бакет, LoRa уходит голым — байты дороги
            let wire = WirePadding.outbound(packet, transport: transportKind)
            link.send(wire, toHost: peerHost) { ok in tally.report(ok) }
        }
    }

    /// Те же пакеты — прямому пути «рядом» (веером всем соседям).
    private func sendNearby(_ item: Outbox.QueuedMessage) {
        let packets = item.packetsHex.map(Outbox.bytes(fromHex:))
        let tally = SendTally(total: packets.count) { [weak self] allOK in
            Task { @MainActor in
                self?.attemptFinished(item, success: allOK, via: "nearby")
            }
        }
        for packet in packets {
            // «рядом» — всегда быстрый канал (Wi-Fi Aware/BLE): в бакет
            NearbyTransport.shared.send(WirePadding.pad(packet)) { ok in
                tally.report(ok)
            }
        }
    }

    // MARK: Штампы пузыря (блок 1, 10.08) — чистые, закрыты замком
    //
    // Спека владельца: id и время сообщения НЕИЗМЕННЫ; транспорт в UI =
    // тот, на котором РЕАЛЬНО доставлено; до того — без ретро-мутаций.
    // Полевой случай 09.08: пузырь «через интернет·10:11» позже
    // становился «по радио·10:14» — успех второго пути перештамповывал
    // и время, и слово транспорта.

    /// Первая реальная передача: sentAt ставится ОДИН раз и больше не
    /// двигается; слово пути НЕ ставится — его назначает только
    /// подтверждённая доставка.
    nonisolated static func stampSentOnce(_ entry: inout ChatEntry,
                                          now: Date = Date()) {
        guard entry.sentAt == nil else { return }
        entry.sentAt = now
    }

    /// Подтверждённая доставка: путь красится тем каналом, который её
    /// подтвердил, — один раз (повторный ack другого пути не перекрашивает).
    nonisolated static func stampDelivered(_ entry: inout ChatEntry,
                                           via: String,
                                           now: Date = Date()) {
        guard entry.deliveredAt == nil else { return }
        entry.deliveredAt = now
        entry.sentVia = via
        entry.status = nil
    }

    private func attemptFinished(_ item: Outbox.QueuedMessage,
                                 success: Bool, via: String) {
        // атомарно (ревизия параллелизма 06.08): чтение, правка и запись
        // очереди — одна критическая секция, а не три вызова врозь
        let firstSuccess = Outbox.mutateQueue { queue -> Bool in
            // ack мог прийти, пока пакет летел — тогда сообщение уже
            // «доставлено» и из очереди убрано, ничего не трогаем
            guard let index = queue.firstIndex(where: { $0.msgID == item.msgID })
            else { return false }
            // при неуспехе очередь НЕ трогаем — счётчик попыток и срок
            // повтора ставит насос (pushQueue), здесь их менять нельзя:
            // поведение сохранено один в один с версией до атомизации
            guard success else { return false }
            let first = queue[index].sent != true
            queue[index].sent = true
            queue[index].confirmedSends = (queue[index].confirmedSends ?? 0) + 1
            // SOS/BEACON не несут ack-флага — после успешной передачи
            // держать их в очереди не за чем, иначе повторы навсегда
            if !queue[index].expectsAck { queue.remove(at: index) }
            return first
        }
        if success {
            // Инструментация атрибуции пути (11.08): пишем реальный
            // путь-НОСИТЕЛЬ каждой успешной передачи. Метка ленты
            // красится путём ACK (stampDelivered в acked), а он может
            // отличаться от носителя — этот дневник ловит расхождение
            // «шло радио (9 мин) / метка через интернет» в следующем
            // же случае. Слепую перекраску метки не делаем: честный
            // ack-по-X требует нового поля на проводе (будущая ревизия).
            TransportDiary.note("[путь] msgID=\(item.msgID) передан "
                                + "по \(via) (\(ChatEntry.pathWord(via) ?? via))")
            if firstSuccess {
                markEntry(entryID: item.entryID,
                          contactID: item.contactID) { entry in
                    // sentAt один раз, слово пути НЕ здесь: успех
                    // передачи ≠ доставка (блок 1; перештамповка 09.08)
                    Self.stampSentOnce(&entry)
                    entry.status = entry.isSOSRelated
                        ? "отправлено контакту" : "отправлено"
                }
            }
        } else {
            // честная строка вместо вечного «отправляется»: если путей
            // нет вовсе — обещание «доставлю, когда окажетесь рядом»
            let relayAlive = RelayTransport.shared.active
            markEntry(entryID: item.entryID,
                      contactID: item.contactID) { entry in
                guard entry.deliveredAt == nil else { return }
                if entry.sentAt != nil {
                    entry.status = "повтор…"
                } else {
                    entry.status = relayAlive
                        ? "повтор…"
                        : "доставлю, когда окажетесь рядом"
                }
            }
        }
        eventCounter += 1
    }

    // MARK: Приём

    /// `via` — канал, которым пакет пришёл («radio»/«lan»/«nearby»/
    /// «relay»): ack, пришедший каналом, и есть подтверждение доставки
    /// ЭТИМ каналом — им красится слово пути в пузыре (блок 1, 10.08).
    private func handle(_ packet: [UInt8], via: String) {
        // паддинг быстрых транспортов (№7, 09.08) снимается до всякого
        // разбора; битая обёртка — молча мимо, как битый конверт
        var packet = packet
        if packet.first == WirePadding.marker {
            guard let inner = WirePadding.unwrap(packet) else { return }
            packet = inner
        }
        // Envelope v2 (02.08): свой разборщик; v1-ветка не трогается.
        // Старый бинарник на этом же месте честно отвергал v2 на
        // decodeHeader («неизвестная версия формата») — WP3.
        if let first = packet.first, first >> 4 == EnvelopeV2.version {
            handleV2(packet, via: via)
            return
        }
        guard let header = try? Envelope.decodeHeader(packet) else { return }
        switch header.msgClass {
        case Envelope.classAck:
            if let ack = try? AckMessage.decodeBody(flags: header.flags,
                                                    msgID: header.msgID,
                                                    packet: packet) {
                acked(msgID: ack.ackMsgID, via: via)
            }
        case Envelope.classRead:
            // отметка прочтения: [заголовок][msgID прочитанного LE]
            if packet.count >= 6 {
                let read = UInt16(packet[4]) | UInt16(packet[5]) << 8
                markRead(wireMsgID: Int(read))
            }
        case Envelope.classText:
            handleText(packet, header: header, via: via)
        case Envelope.classLocation:
            handleLocation(packet, header: header)
        case Envelope.classSOS:
            handleSOS(packet, header: header)
        case Envelope.classBeacon:
            handleBeacon(packet, header: header)
        default:
            break
        }
    }

    // MARK: Приём v2 (рэтчет Б + адресация; Envelope v2, 02.08)

    private var pendingV2: [UInt16: (total: Int, chunks: [Int: [UInt8]])] = [:]

    // ── FRAG2 (B3, подпись п.7): пул сборки с бюджетами ───────────────
    /// Потолок параллельных пересборок (транспортный бюджет).
    static let frag2MaxParallel = 8
    /// Транспортный потолок msg_len (конвертный — 16 МиБ; здесь жёстче:
    /// длиннее текст/голос v1 не бывает, памятью не рискуем).
    static let frag2TransportMsgLenCap = 2 * 1024 * 1024
    private let frag2Pool = Frag2Assembler()

    /// Псевдоним адресован мне? С 04.08 ящик у каждой пары свой
    /// (dst зависит от ключа пары), поэтому перебираются контакты.
    /// Стоимость: число контактов × число эпох окна SHA-256 на пакет —
    /// на десятках контактов это микросекунды.
    nonisolated static func dstIsForMe(_ dst: [UInt8],
                                       now: Date = Date()) -> Bool {
        guard let myPriv = Identity.privateKey(),
              let myPub = Identity.publicKey() else { return false }
        let mine = myPub.rawRepresentation
        // Ящик первого контакта (незнакомец, ещё не в контактах): кадр
        // интро приходит на dst, выводимый из МОЕГО ключа — иначе
        // получатель отверг бы интро на этом гейте (дизайн-дыра 11.08).
        if FirstContactMailbox.isMine(dst, myPub: mine, now: now) {
            return true
        }
        for contact in ContactStore.load() {
            guard let peer = contact.publicKey,
                  let key = try? MailboxID.pairKey(myPrivate: myPriv,
                                                   peerPublic: peer)
            else { continue }
            if MailboxID.isMine(dst, myPub: mine, pairKey: key, now: now) {
                return true
            }
        }
        return false
    }

    func handleV2(_ packet: [UInt8], via: String = "radio") {
        guard let frame = try? EnvelopeV2.decode(packet) else { return }
        // Адресный блок: чужие псевдонимы отбрасываются молча. С 04.08
        // dst зависит от КЛЮЧА ПАРЫ (эпохи со сдвигом, см. MailboxID),
        // поэтому проверяем окно по каждому известному контакту:
        // у каждого корреспондента свой ящик.
        if let dst = frame.dst {
            guard Self.dstIsForMe(dst) else { return }
        }
        var stream = frame.stream
        if let frag2 = frame.frag2 {
            // Бюджеты (подпись п.7): ленивая сборка уже в ассемблере;
            // здесь — потолок msg_len и параллельных пересборок. Провал
            // AEAD ниже сборку не хоронит: пул запись уже отдал, повтор
            // набора кусков даст новую попытку (остаточный пункт).
            guard frag2.msgLen <= Self.frag2TransportMsgLenCap else {
                TransportDiary.note("[frag2] msg_len \(frag2.msgLen) выше "
                    + "транспортного потолка — кадр отброшен")
                return
            }
            if frag2Pool.pendingCount >= Self.frag2MaxParallel {
                TransportDiary.note("[frag2] пул пересборок полон "
                    + "(\(Self.frag2MaxParallel)) — кадр отброшен")
                return
            }
            guard let emission = try? frag2Pool.add(
                msgID: frame.msgID, index: frag2.index, total: frag2.total,
                msgLen: frag2.msgLen, chunk: stream,
                now: Date().timeIntervalSince1970),
                  emission.completed, let assembled = emission.stream
            else { return }   // дырка/несходящийся кадр — ждём/отброшен
            stream = assembled
        } else if let fragment = frame.fragment {
            var entry = pendingV2[frame.msgID]
                ?? (fragment.total, [:])
            entry.chunks[fragment.index] = stream
            pendingV2[frame.msgID] = entry
            guard entry.chunks.count == entry.total else { return }
            stream = (0..<entry.total).compactMap { entry.chunks[$0] }
                .flatMap { $0 }
            pendingV2[frame.msgID] = nil
        }
        processV2Stream(stream, msgID: frame.msgID, wantAck: frame.wantAck,
                        via: via)
    }

    private func processV2Stream(_ stream: [UInt8], msgID: UInt16,
                                 wantAck: Bool, via: String) {
        guard let first = stream.first else { return }
        let header = (msgClass: Envelope.classText,
                      flags: wantAck ? Envelope.flagAckRequest : 0,
                      msgID: msgID)

        if first == E2ESeal.codecSealed {
            guard let identity = Identity.privateKey() else { return }
            // ratchet-init? (рукопожатие/ре-ключ/проба)
            if let accepted = try? RatchetHandshake.accept(sealed: stream,
                                                           identity: identity) {
                guard let senderKey = try? Curve25519.KeyAgreement.PublicKey(
                    rawRepresentation: Data(accepted.senderPub)) else { return }
                let senderID = Identity.fingerprint(of: senderKey)
                // B2: неизвестный ключ рождает контакт с первого
                // сообщения (встречный скан не обязателен); блокнутый —
                // гасится молча
                guard let admittedID = ContactAdmission.admit(
                    senderID: senderID,
                    senderPubRaw: accepted.senderPub),
                      let contact = ContactStore.load()
                          .first(where: { $0.id == admittedID })
                else { return }
                // Повтор ТОГО ЖЕ рукопожатия (релей отдаёт кадры
                // at-least-once, «рядом» повторяет до ack) не должен
                // сбрасывать живую эпоху: обнуление счётчиков заново
                // открывает уже прочитанные session-сообщения — так
                // полевой прогон 08.08 получил дубль в ленте. Своя
                // эпоха с тем же seed уже стоит — молча пропускаем.
                if let existing = RatchetStore.load(contactID: contact.id),
                   existing.seedFingerprint == accepted.epoch.seedFingerprint {
                    return
                }
                var epoch = accepted.epoch
                epoch.peerConfirmedV2 = true   // он прислал v2 — умеет
                RatchetStore.save(epoch, contactID: contact.id)
                if !accepted.data.isEmpty {
                    deliver(payload: [accepted.innerCodec] + accepted.data,
                            header: header,
                            sentAtMinutes: accepted.sentAtMinutes,
                            presetSenderID: contact.id, via: via)
                }
                eventCounter += 1
                return
            }
            // обычный v2-sealed: [ts 4][pub 32][кодек][данные] внутри ct
            guard let opened = try? E2ESeal.open(sealed: stream,
                                                 identity: identity),
                  opened.count > 37 else { return }
            let ts = UInt32(opened[0]) | UInt32(opened[1]) << 8
                | UInt32(opened[2]) << 16 | UInt32(opened[3]) << 24
            let senderRaw = Array(opened[4..<36])
            let senderID = (try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: Data(senderRaw)))
                .map(Identity.fingerprint(of:))
            // ВАЖНО: v2-sealed НЕ подтверждает сессию. Он доказывает,
            // что собеседник говорит v2, но не что у него есть НАША
            // эпоха (через релей v2-sealed шлют и без эпохи). Переход
            // на session-кодек — только по session-сообщению собеседника
            // (ветка ниже): оно единственное доказывает эпоху. Иначе мы
            // начали бы шифровать тому, кто расшифровать не может.
            // ключ отправителя — дальше, в deliver: без него admit не
            // звался, незнакомец не рождал контакт, и ПЕРВОЕ сообщение
            // (v2-sealed через ящик первого контакта) падало в демо-ленту
            // (полевой дефект 13.08; замок firstSealedFrameDelivers…)
            deliver(payload: Array(opened.dropFirst(36)), header: header,
                    sentAtMinutes: ts, presetSenderID: senderID,
                    presetSenderPubRaw: senderRaw, via: via)
            return
        }

        // ── Рев B: кодеки 5/6 (подпись шва, транспортная половина) ──
        if first == EnvelopeRevB.codecSealed2 {
            guard let myPriv = Identity.privateKey(),
                  stream.count > E2ESeal2.overhead else { return }
            let wireTag = Array(stream[33..<35])
            for contact in ContactStore.load() {
                guard let peerPub = contact.publicKey,
                      let pairKey = try? MailboxID.pairKey(
                        myPrivate: myPriv, peerPublic: peerPub) else { continue }
                // окно эпох тега — то же, что у ящиков (Т1)
                let epochs = MailboxID.acceptedEpochs(pairKey: pairKey)
                guard epochs.contains(where: {
                    E2ESeal2.senderTag(pairKey: pairKey, epoch: $0) == wireTag
                }) else { continue }
                guard let opened = try? E2ESeal2.open(
                    sealed: stream, identity: myPriv, senderPub: peerPub),
                      let prefix = try? RevBPrefix.decode(opened)
                else { continue }   // коллизия тега — пробуем следующего
                PeerCaps.markRevB(contactID: contact.id)
                routeRevB(prefix: prefix, header: header,
                          contactID: contact.id, via: via)
                return
            }
            return   // тег не совпал ни с кем — не наше, молча
        }

        if first == EnvelopeRevB.codecSession2 {
            for contact in ContactStore.load() {
                guard var epoch = RatchetStore.load(contactID: contact.id)
                else { continue }
                do {
                    let message = try epoch.openMessage2(stream: stream)
                    RatchetStore.save(epoch, contactID: contact.id)
                    PeerCaps.markSession2(contactID: contact.id)
                    routeRevB(prefix: RevBPrefix(
                        sentAtSeconds: message.sentAtSeconds,
                        seq: message.seq,
                        innerCodec: message.innerCodec,
                        data: message.data),
                              header: header, contactID: contact.id, via: via)
                    return
                } catch RatchetError.notForUs {
                    continue
                } catch RatchetError.duplicate {
                    return
                } catch {
                    RatchetStore.drop(contactID: contact.id)
                    var log = HumanChatStore.loadLog(contactID: contact.id)
                    log.append(ChatEntry(
                        kind: .incoming,
                        text: "⚠︎ Сеанс обновлён — попросите собеседника "
                            + "отправить сообщение ещё раз"))
                    HumanChatStore.saveLog(log, contactID: contact.id)
                    eventCounter += 1
                    return
                }
            }
            return
        }
        // ── конец веток рев B ───────────────────────────────────────

        if first == EnvelopeV2.codecSession {
            for contact in ContactStore.load() {
                guard var epoch = RatchetStore.load(contactID: contact.id)
                else { continue }
                do {
                    let message = try epoch.openMessage(stream: stream)
                    epoch.peerConfirmedV2 = true
                    RatchetStore.save(epoch, contactID: contact.id)
                    deliver(payload: [message.innerCodec] + message.data,
                            header: header,
                            sentAtMinutes: message.sentAtMinutes,
                            presetSenderID: contact.id, via: via)
                    return
                } catch RatchetError.notForUs {
                    continue
                } catch RatchetError.duplicate {
                    return   // ветвление радио+релей: второй экземпляр
                } catch {
                    // дыра глубже потолка / TTL / разошлось состояние:
                    // сессию похоронить, собеседнику — честная строка;
                    // новое рукопожатие уедет с нашей следующей отправкой
                    RatchetStore.drop(contactID: contact.id)
                    var log = HumanChatStore.loadLog(contactID: contact.id)
                    log.append(ChatEntry(
                        kind: .incoming,
                        text: "⚠︎ Сеанс обновлён — попросите собеседника "
                            + "отправить сообщение ещё раз"))
                    HumanChatStore.saveLog(log, contactID: contact.id)
                    eventCounter += 1
                    return
                }
            }
            // тег не совпал ни с одной сессией — не наше или мёртвый
            // сеанс неизвестного отправителя; отправителя v2 не выдаёт,
            // спросить некого — молча (отчёт: свойство формата)
        }
    }

    /// Маршрутизация вскрытого рев-B-кадра (подпись шва п.4): позиция
    /// (внутренний кодек 7) — в PeerPositionStore со всеми правилами
    /// приёмника, остальное — в ленту через deliver с секундами и seq.
    private func routeRevB(prefix: RevBPrefix,
                           header: (msgClass: UInt8, flags: UInt8, msgID: UInt16),
                           contactID: String, via: String) {
        if prefix.innerCodec == EnvelopeRevB.codecPosition {
            // дедуп кадра — msgID (подпись п.3), реплей точки — seq
            var seen = SeenMsgIDs(
                ids: UserDefaults.standard.array(forKey: Self.seenKey)
                    as? [Int] ?? [])
            let fresh = seen.insert(header.msgID)
            UserDefaults.standard.set(seen.ids, forKey: Self.seenKey)
            guard fresh else { return }
            guard SeqStore.acceptPosition(contactID: contactID,
                                          seq: prefix.seq) else {
                TransportDiary.note("[гео] позиция со старым seq "
                    + "отброшена (реплей)")
                return
            }
            guard let position = try? PositionPayload.decode(
                [prefix.innerCodec] + prefix.data) else { return }
            // клэмп будущего: часы отправителя врут (полевое 10.08)
            let measured = min(Date(timeIntervalSince1970:
                TimeInterval(position.measuredAt)), Date())
            _ = measured   // PeerPositionStore хранит момент приёма
            PeerPositionStore.shared.ingest(contactID: contactID,
                                            lat: position.lat,
                                            lon: position.lon,
                                            receivedAt: Date())
            TransportDiary.note("[гео] позиция принята кодеком 7 (рев B)")
            eventCounter += 1
            if header.flags & Envelope.flagAckRequest != 0 {
                pendingAcks.add(header.msgID, contactID: contactID,
                                now: Date())
            }
            return
        }
        deliver(payload: [prefix.innerCodec] + prefix.data,
                header: header,
                presetSenderID: contactID, via: via,
                revBSeconds: prefix.sentAtSeconds, revBSeq: prefix.seq)
    }

    // MARK: Релейный путь (05.08)

    /// Приём кадра, добытого опросом ящика: тот же разборщик, что у
    /// радио, — v2-рамка с dst проходит handleV2 → dstIsForMe.
    func ingest(_ packet: [UInt8]) {
        handle(packet, via: "relay")
    }

    /// Кадр лёг в ящик (200 после fsync релея).
    func relayStored(_ item: Outbox.QueuedMessage, dstHex: String,
                     epoch: Int, framesHex: [String]) {
        let found = Outbox.mutateQueue { queue -> Bool in
            guard let index = queue.firstIndex(where: { $0.msgID == item.msgID })
            else { return false }
            queue[index].relayDstHex = dstHex
            queue[index].relayEpoch = epoch
            queue[index].relayStoredAt = Date()
            queue[index].relayFramesHex = framesHex
            return true
        }
        guard found else { return }
        markEntry(entryID: item.entryID, contactID: item.contactID) { entry in
            guard entry.deliveredAt == nil else { return }
            // sentAt один раз; слово пути укладка в ящик НЕ назначает —
            // путь красится только подтверждённой доставкой (блок 1;
            // раньше ящик перекрашивал отправку соседу, прогон 08.08)
            Self.stampSentOnce(&entry)
            entry.status = "в ящике у получателя"
        }
        eventCounter += 1
    }

    /// Получатель забрал кадр (его DELETE опустошил ящик до TTL) —
    /// это и есть «доставлено» релейного пути.
    func relayDelivered(_ item: Outbox.QueuedMessage) {
        Outbox.mutateQueue { queue in
            if let index = queue.firstIndex(where: { $0.msgID == item.msgID }) {
                queue.remove(at: index)
            }
        }
        markEntry(entryID: item.entryID, contactID: item.contactID) { entry in
            // ack соседа мог подтвердить доставку раньше — тогда забор
            // кадра из ящика лишь подчистил дубль, а не доставил:
            // слово «рядом» остаётся (полевой прогон 08.08); guard
            // внутри stampDelivered
            Self.stampDelivered(&entry, via: "relay")
        }
        eventCounter += 1
    }

    /// Релейный путь завершён без доставки (410, битый кадр, чужой
    /// ключ) — с основанием, не по счётчику. Радио, если оно есть,
    /// продолжает свои попытки.
    func relayTerminal(_ item: Outbox.QueuedMessage, status: String) {
        var queue = Outbox.loadQueueRaw()
        if let index = queue.firstIndex(where: { $0.msgID == item.msgID }) {
            queue[index].relayDone = true
            if !radioReady {
                // слать больше некуда и незачем — очередь не копит мёртвое
                queue.remove(at: index)
            }
            Outbox.saveQueueRaw(queue)
        }
        markEntry(entryID: item.entryID, contactID: item.contactID) { entry in
            guard entry.deliveredAt == nil else { return }
            entry.status = status
        }
        eventCounter += 1
    }

    /// Промежуточный исход релея (507/503/сеть) — строка человеку,
    /// повторы продолжаются.
    func relayNote(_ item: Outbox.QueuedMessage, status: String) {
        markEntry(entryID: item.entryID, contactID: item.contactID) { entry in
            guard entry.deliveredAt == nil, entry.sentAt == nil else { return }
            entry.status = status
        }
        eventCounter += 1
    }

    /// Какими путями сейчас можно отправить — для статусной строки.
    /// Учитывает ручные галочки: путь, снятый человеком, не обещается.
    /// Пустая маска — честное «пути отключены», а не «доставлю, когда
    /// окажетесь рядом» (полевой прогон 13.08: сняли все галочки и
    /// ждали доставку, статус обещал невозможное).
    var pathSummary: String {
        if TransportMode.isManual, TransportMode.manualMask.isEmpty {
            return "пути отключены в настройках"
        }
        if RelayTransport.shared.active, TransportMode.wifiAllowed {
            return "через интернет"
        }
        if nearbyReady, TransportMode.bleAllowed { return "рядом" }
        if radioReady && nodeCount > 0, TransportMode.loraAllowed {
            return "устройств рядом: \(nodeCount)"
        }
        return "доставлю, когда окажетесь рядом"
    }

    /// Принят чужой SOS: запись в чат отправителя красным + звук.
    /// Wire-формат SOS не несёт отправителя (класс открытый, по спеке):
    /// атрибутируем как LOCATION — только в конфигурации «ровно один
    /// контакт»; иначе сигнал кладётся в демо-ленту, но не теряется.
    private func handleSOS(_ packet: [UInt8],
                           header: (msgClass: UInt8, flags: UInt8, msgID: UInt16)) {
        guard let sos = try? SOSMessage.decodeBody(flags: header.flags,
                                                   msgID: header.msgID,
                                                   packet: packet) else { return }
        var seen = SeenMsgIDs(
            ids: UserDefaults.standard.array(forKey: Self.seenKey)
                as? [Int] ?? [])
        let fresh = seen.insert(header.msgID)
        UserDefaults.standard.set(seen.ids, forKey: Self.seenKey)
        guard fresh else { return }

        var parts = ["SOS! Срочность: "
                     + (NeedsMapping.severityNames[sos.severity] ?? "—"),
                     "людей: \(sos.peopleCount)"]
        if sos.injury != 0 {
            parts.append("травма: "
                         + (NeedsMapping.injuryNames[sos.injury] ?? "—"))
        }
        let needs = sos.needs.sorted()
            .compactMap { NeedsMapping.bitNames[$0] }
            .joined(separator: ", ")
        if !needs.isEmpty { parts.append("нужно: \(needs)") }
        if let lat = sos.lat, let lon = sos.lon {
            parts.append(String(format: "примерно здесь: %.4f, %.4f "
                                + "(точность ~300×600 м)", lat, lon))
        }

        var entry = ChatEntry(kind: .incoming,
                              text: parts.joined(separator: " · "))
        entry.sosRelated = true
        let contacts = ContactStore.load()
        let contactID = contacts.count == 1 ? contacts[0].id : nil
        var log = HumanChatStore.loadLog(contactID: contactID)
        log.append(entry)
        HumanChatStore.saveLog(log, contactID: contactID)
        SOSAlert.play()
        eventCounter += 1
    }

    /// Принят BEACON: интересен отбой (статус «ситуация решена»).
    private func handleBeacon(_ packet: [UInt8],
                              header: (msgClass: UInt8, flags: UInt8, msgID: UInt16)) {
        guard let beacon = try? BeaconMessage.decodeBody(flags: header.flags,
                                                         msgID: header.msgID,
                                                         packet: packet)
        else { return }
        var seen = SeenMsgIDs(
            ids: UserDefaults.standard.array(forKey: Self.seenKey)
                as? [Int] ?? [])
        let fresh = seen.insert(header.msgID)
        UserDefaults.standard.set(seen.ids, forKey: Self.seenKey)
        guard fresh else { return }

        let text: String
        switch beacon.status {
        case 1: text = "К отправителю SOS уже идёт помощь"
        case 2: text = "Отбой — помощь больше не нужна"
        default: text = "Отправителю SOS всё ещё нужна помощь"
        }
        let entry = ChatEntry(kind: .incoming, text: text)
        let contacts = ContactStore.load()
        let contactID = contacts.count == 1 ? contacts[0].id : nil
        var log = HumanChatStore.loadLog(contactID: contactID)
        log.append(entry)
        HumanChatStore.saveLog(log, contactID: contactID)
        eventCounter += 1
    }

    /// Позиция собеседника → единственное хранилище PeerPositionStore.
    /// Wire-формат LOCATION не несёт отправителя (открытые байты §5,
    /// шифрование LOCATION спекой заявлено, но не определено — см.
    /// REPORT_map_night.md): атрибутируем только в однозначной
    /// конфигурации «ровно один контакт» (полевая 1:1); иначе пакет
    /// честно отбрасывается, а не приписывается наугад.
    /// Срок гашения ПРИЁМА открытого 0x5 (подпись п.6): переходные
    /// сборки ≤ рев B шлют его в 1:1 — не режем до полного перехода;
    /// после срока приём гаснет КОДОМ (образец IntroduceWire.v1ReplySunset).
    static let locationV0Sunset = Date(timeIntervalSince1970: 1_793_491_200)

    /// internal — замок sunset подставляет now за срок гашения.
    func handleLocation(_ packet: [UInt8],
                        header: (msgClass: UInt8, flags: UInt8, msgID: UInt16),
                        now: Date = Date()) {
        guard now < Self.locationV0Sunset else {
            TransportDiary.note("[гео] открытый 0x5 после срока снятия — "
                + "погашен")
            return
        }
        guard let loc = try? LocationMessage.decodeBody(flags: header.flags,
                                                        msgID: header.msgID,
                                                        packet: packet),
              let lat = loc.lat, let lon = loc.lon else { return }
        let contacts = ContactStore.load()
        guard contacts.count == 1 else { return }
        PeerPositionStore.shared.ingest(contactID: contacts[0].id,
                                        lat: lat, lon: lon,
                                        receivedAt: Date())
        eventCounter += 1
    }

    private func acked(msgID: UInt16, via: String) {
        var queue = Outbox.loadQueueRaw()
        guard let index = queue.firstIndex(where: { $0.msgID == msgID })
        else { return }
        let item = queue[index]
        // Инструментация атрибуции (11.08): путь ACK и итоговая метка —
        // рядом с дневником «передан по X», чтобы носитель и метка
        // сверялись глазами в одном логе (расхождение = мислейбл)
        TransportDiary.note("[путь] msgID=\(msgID) ПОДТВЕРЖДЁН по \(via) "
                            + "→ метка ленты «\(ChatEntry.pathWord(via) ?? via)»")
        markEntry(entryID: item.entryID, contactID: item.contactID) { entry in
            // слово пути = канал, ПОДТВЕРДИВШИЙ доставку (блок 1)
            Self.stampDelivered(&entry, via: via)
        }
        queue.remove(at: index)
        Outbox.saveQueueRaw(queue)
        eventCounter += 1
    }

    private func handleText(_ packet: [UInt8],
                            header: (msgClass: UInt8, flags: UInt8, msgID: UInt16),
                            via: String) {
        let packetVersion = packet[0] >> 4
        var payload = Array(packet[Envelope.headerSize...])
        if header.flags & Envelope.flagFragmented != 0 {
            guard payload.count > 2 else { return }
            let index = Int(payload[0]), total = Int(payload[1])
            var entry = pending[header.msgID] ?? (total, [:])
            entry.chunks[index] = Array(payload[2...])
            pending[header.msgID] = entry
            guard entry.chunks.count == entry.total else { return }
            payload = (0..<entry.total).compactMap { entry.chunks[$0] }
                .flatMap { $0 }
            pending[header.msgID] = nil
        }
        // v1: 4 байта unix-минут отправки — префикс потока нагрузки
        var sentAtMinutes: UInt32 = 0
        if packetVersion >= 1, payload.count >= 4 {
            sentAtMinutes = UInt32(payload[0]) | UInt32(payload[1]) << 8
                | UInt32(payload[2]) << 16 | UInt32(payload[3]) << 24
            payload = Array(payload.dropFirst(4))
        }
        deliver(payload: payload, header: header,
                sentAtMinutes: sentAtMinutes, via: via)
    }

    private func deliver(payload: [UInt8],
                         header: (msgClass: UInt8, flags: UInt8, msgID: UInt16),
                         sentAtMinutes: UInt32 = 0,
                         presetSenderID: String? = nil,
                         presetSenderPubRaw: [UInt8]? = nil,
                         via: String = "radio",
                         revBSeconds: UInt32? = nil,
                         revBSeq: UInt32? = nil) {
        var inner = payload
        var senderID: String? = presetSenderID
        var senderPubRaw: [UInt8]? = presetSenderPubRaw
        if inner.first == E2ESeal.codecSealed {
            guard let identity = Identity.privateKey(),
                  let opened = try? E2ESeal.open(sealed: inner,
                                                 identity: identity),
                  opened.count > 33 else { return }
            // внутри: [pubkey отправителя 32][кодек][данные]
            if let senderKey = try? Curve25519KeyFromRaw(Array(opened[0..<32])) {
                senderID = Identity.fingerprint(of: senderKey)
                senderPubRaw = Array(opened[0..<32])
            }
            inner = Array(opened[32...])
        }
        // B2: блок помнит ключ — входящее от заблокированного гасится
        // до ленты (ack транспортного уровня при этом честен: «дошло»,
        // но никогда не показано)
        if let senderID, ContactAdmission.isBlocked(id: senderID) {
            TransportDiary.note("[допуск] входящее от блокнутого "
                                + "\(senderID) погашено")
            return
        }
        guard var text = try? TextCodec.decompress(Array(inner.dropFirst()),
                                                   codec: inner[0]) else { return }
        if sentAtMinutes > 0 {
            // Ф5: относительное время рендерится ОТ метки отправки
            text = RMCodec.applySentTime(text,
                                         sentAtMinutes: sentAtMinutes,
                                         lang: RMCodec.unfoldLanguage)
        }
        // дедуп повторов: сообщение уже показывали — в ленту не кладём,
        // но ack шлём снова (прошлый ack мог потеряться)
        var seen = SeenMsgIDs(
            ids: UserDefaults.standard.array(forKey: Self.seenKey)
                as? [Int] ?? [])
        let fresh = seen.insert(header.msgID)
        UserDefaults.standard.set(seen.ids, forKey: Self.seenKey)
        if !fresh {
            // второй путь доставки (радио+релей или повтор ящика)
            TransportDiary.note("[дедуп] msgID \(header.msgID) погашен")
        }
        if fresh {
            // дата записи = время ОТПРАВКИ из пакета (полевой прогон
            // 10.08: залповая разгрузка ломала порядок ленты); часы
            // отправителя из будущего ленту не двигают — клэмп.
            // Метка минутная — залп ОДНОЙ минуты растаскивается
            // тай-брейком: +1 мс к последней записи той же минуты,
            // порядок прихода внутри минуты сохраняется. Секундная
            // точность в самом пакете — аддитивный пункт конвертной
            // ревизии (формат в одиночку не открываем).
            // чат отправителя; неизвестный С КЛЮЧОМ рождает контакт
            // (B2: встречный скан не обязателен); без ключа — демо-лента
            let contactID = senderID.flatMap { id -> String? in
                if let raw = senderPubRaw {
                    return ContactAdmission.admit(senderID: id,
                                                  senderPubRaw: raw)
                }
                return ContactStore.load().first { $0.id == id }?.id
            }
            var log = HumanChatStore.loadLog(contactID: contactID)
            var entryDate = Date()
            if let revBSeconds, let revBSeq {
                // Рев B (шов №4): порядок держит seq, секунды — показ.
                // Рост seq — честная секунда отправки + доли по seq
                // (внутрисекундный порядок); сброс отсчёта → откат к
                // порядку прихода (существующий тай-брейк по логу).
                let sent = Date(timeIntervalSince1970:
                                    TimeInterval(revBSeconds))
                let clamped = min(sent, entryDate)
                let verdict = contactID.map {
                    SeqStore.noteIncoming(contactID: $0, seq: revBSeq)
                } ?? .ordered
                if verdict == .stale || verdict == .ordered {
                    entryDate = clamped.addingTimeInterval(
                        Double(revBSeq % 1000) / 1000.0)
                } else {
                    // resetDetected: порядок прихода, как для минутных
                    let last = log.map(\.date).max()
                    if let last, last >= clamped {
                        entryDate = last.addingTimeInterval(0.001)
                    } else {
                        entryDate = clamped
                    }
                    TransportDiary.note("[лента] сброс отсчёта seq у "
                        + "контакта — порядок прихода")
                }
            } else if sentAtMinutes > 0 {
                let sent = Date(timeIntervalSince1970:
                                    TimeInterval(sentAtMinutes) * 60)
                if sent < entryDate { entryDate = sent }
                // тай-брейк залпа одной минуты: +1 мс к последней
                // записи той же минуты — ПОРЯДОК ПРИХОДА СОХРАНЯЕТСЯ.
                // Учитываем записи ЛЮБОГО вида, не только входящие
                // (полевое 12.08): входящее датируется полом минуты
                // (17:09:00), а МОЁ исходящее — реальным локальным
                // временем (17:09:10); фильтр только по incoming ставил
                // ответ собеседника ВЫШЕ моего вопроса той же минуты.
                // Полная кросс-устройственная точность — секунды/seq в
                // проводе (ревизия B, шов), здесь — честный локальный
                // порядок прихода.
                let minuteStart = TimeInterval(sentAtMinutes) * 60
                let lastSameMinute = log.lazy
                    .map(\.date)
                    .filter { $0.timeIntervalSince1970 >= minuteStart
                        && $0.timeIntervalSince1970 < minuteStart + 60 }
                    .max()
                if let last = lastSameMinute, last >= entryDate {
                    entryDate = last.addingTimeInterval(0.001)
                }
            }
            var entry = ChatEntry(kind: .incoming, text: text,
                                  date: entryDate)
            // момент прихода — для непрочитанного и подъёма чата:
            // date выше — время ОТПРАВКИ, оно бывает раньше открытия
            // чата, и счётчик молчал (полевой дефект 13.08)
            entry.receivedAt = Date()
            // честная метка канала прихода (поле 13.08: у входящих
            // метки транспорта не было вовсе)
            entry.receivedVia = via
            entry.wireMsgID = Int(header.msgID)   // для отметки прочтения
            if inner[0] == Envelope.codecSemantic {
                entry.semanticBlob = Array(inner.dropFirst())
            }
            // пришло прямым путём — значит, этот человек сейчас рядом
            if receivingFromNearby, let contactID {
                NearbyPresence.shared.markSeenNearby(contactID: contactID)
            }
            // Ответ на мой активный SOS (3.5): личное сообщение от того,
            // кто получил сигнал, — красная подсветка + особый звук
            if SOSCenter.activeSessionCovers(contactID: contactID) {
                entry.sosRelated = true
                SOSAlert.play()
            }
            log.append(entry)
            HumanChatStore.saveLog(log, contactID: contactID)
            eventCounter += 1
            // фон (ядро, поручение 10.08): человек обязан узнать о
            // входящем, не открывая приложение
            IncomingNotifier.post(senderName: ContactStore.load()
                .first { $0.id == contactID }?.name, text: text)
        }

        // подтверждение доставки — в копилку, не в канал напрямую:
        // мгновенный ack на каждый пакет залпового дренажа клинил
        // PhoneAPI узла (03.08); копилку сдаёт насос после тишины приёма.
        // Условия «peerHost задан» здесь НЕТ: это реликт LAN-эпохи —
        // на телефонах peerHost пуст, и ack не ставился вовсе (полевой
        // прогон 08.08: сосед повторял одно сообщение 20 минут, а
        // «доставлено» появлялось только через релей)
        if header.flags & Envelope.flagAckRequest != 0 {
            pendingAcks.add(header.msgID, contactID: senderID, now: Date())
        }
    }

    /// internal (не private) — замок NearbyFieldFixTests заглядывает
    /// в копилку: ack обязан ставиться и при пустом peerHost
    var pendingAcks = AckAggregator()

    /// Показать/снять тревогу детектора клина. Если на телефоне стоит
    /// официальный клиент Meshtastic — назвать его: он делит с нами
    /// одну очередь узла и перехватывает пакеты (диагноз 03.08).
    private func showLinkWarning(_ warning: String?) {
        guard var text = warning else {
            linkWarning = nil
            return
        }
        if Self.officialClientInstalled() {
            text += " Если открыт официальный клиент Meshtastic — "
                  + "закройте его: он перехватывает пакеты."
        }
        linkWarning = text
    }

    /// Установлен ли официальный клиент Meshtastic (схема meshtastic://
    /// объявлена в LSApplicationQueriesSchemes). Работает ли он сейчас —
    /// песочница iOS знать не даёт, поэтому формулировка «если открыт».
    static func officialClientInstalled() -> Bool {
        guard let url = URL(string: "meshtastic://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Каналы для служебных пакетов (ack/квитанции) с учётом РУЧНОЙ
    /// маски (поле 13.08, build 19: снятая галка «Рядом» не глушила
    /// ack-путь — сообщения «летели как рядом» вопреки тумблеру).
    /// Чистая функция — под замком.
    nonisolated static func serviceChannels(radioReady: Bool,
                                            nearbyReady: Bool,
                                            relayReady: Bool,
                                            loraAllowed: Bool,
                                            bleAllowed: Bool)
    -> (radio: Bool, nearby: Bool, relay: Bool) {
        // relayReady = RelayTransport.active: разрешение галки wifi уже
        // внутри (поле 29.09 — enabled выводится из TransportMode)
        (radio: radioReady && loraAllowed,
         nearby: nearbyReady && bleAllowed,
         relay: relayReady)
    }

    /// Сдать накопленные подтверждения (вызывается тиком насоса).
    /// Ack уходит всеми живыми РАЗРЕШЁННЫМИ путями: потеряется —
    /// отправитель повторит сообщение, ack уйдёт снова; дубль стерпит
    /// дедуп.
    private func flushAcks(now: Date = Date()) {
        let channels = Self.serviceChannels(
            radioReady: radioReady, nearbyReady: nearbyReady,
            relayReady: RelayTransport.shared.active,
            loraAllowed: TransportMode.loraAllowed,
            bleAllowed: TransportMode.bleAllowed)
        for (id, contactID) in pendingAcks.takeDueWithContacts(now: now) {
            let packet = AckMessage(msgID: Envelope.newMsgID(),
                                    ackMsgID: id).encode()
            // в канал — только если радио реально сконфигурировано:
            // DemoLoopback ack честно теряет, слать туда незачем
            if channels.radio { link.send(packet, toHost: peerHost) }
            if channels.nearby {
                NearbyTransport.shared.send(packet) { _ in }
            }
            // Поле 29.09: в форс-«только интернет» подтверждению
            // доставки некуда было уйти — доставленное вечно висело
            // «ждём собеседника». Релей кладёт ack в ящик пары.
            if channels.relay, let contactID {
                RelayTransport.shared.sendService(packet,
                                                  contactID: contactID)
            }
        }
    }

    /// Входящее прочитано получателем — вторая отметка зеленеет.
    private func markRead(wireMsgID: Int) {
        TransportDiary.note("[квитанции] пришла отметка wire=\(wireMsgID)")
        for contact in ContactStore.load().map(\.id) + [nil as String?].compactMap({ $0 }) {
            var log = HumanChatStore.loadLog(contactID: contact)
            guard let index = log.firstIndex(where: {
                $0.wireMsgID == wireMsgID && $0.kind == .outgoing
            }) else { continue }
            guard log[index].readAt == nil else { return }
            log[index].readAt = Date()
            HumanChatStore.saveLog(log, contactID: contact)
            eventCounter += 1
            return
        }
    }

    /// Отправить отметки прочтения по входящим этого чата.
    /// Вызывается при открытии чата: получатель подтверждает, что
    /// увидел сообщения (просьба владельца 02.08).
    /// Настройка «сообщать о прочтении» (решение владельца 03.08:
    /// класс в проводе остаётся, отправка — настройкой, по умолчанию
    /// включена). Выключение не ломает совместимость: собеседник просто
    /// не получит отметку и второе время останется жёлтым.
    static let readReceiptsKey = "chat.sendReadReceipts"
    static var readReceiptsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: readReceiptsKey)
                as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: readReceiptsKey) }
    }

    /// Чаты-должники квитанций (поле 13.08, build 19, «жёлтый не
    /// снимается»): квитанция слалась ОДИН раз при открытии чата —
    /// мёртвое BLE-окно теряло её до следующего открытия. Открытый
    /// чат записывается сюда, насос ретраит каждый тик, пока все
    /// входящие чата не заквитированы (стамп — по подтверждению).
    private(set) var receiptDebtors: Set<String> = []

    /// Полный сброс (начать заново): должников больше нет.
    func clearReceiptDebtors() { receiptDebtors.removeAll() }

    /// Ключ должника: contactID или "" для демо-ленты.
    private static func debtorKey(_ contactID: String?) -> String {
        contactID ?? ""
    }

    /// Тик насоса: дослать квитанции должникам. Должник свободен,
    /// когда неквитированных входящих у него не осталось.
    /// internal + sendOverride — под замком (ретрай после потери).
    /// `only` — ограничение одним чатом (только для замков: общий
    /// реестр + override «всё ок» иначе доштамповывает должников
    /// ПАРАЛЛЕЛЬНЫХ тестов — поймано сюитой 14.08).
    func retryReadReceipts(only: String? = nil,
                           sendOverride: ((_ packet: [UInt8],
                                           _ completion: @escaping @Sendable (Bool) -> Void)
                                          -> Void)? = nil) {
        for key in receiptDebtors {
            if let only, key != only { continue }
            let contactID = key.isEmpty ? nil : key
            let unreceipted = HumanChatStore.loadLog(contactID: contactID)
                .contains { $0.kind == .incoming && $0.wireMsgID != nil
                            && $0.readAt == nil }
            guard unreceipted else {
                receiptDebtors.remove(key)
                continue
            }
            sendReadReceipts(contactID: contactID, sendOverride: sendOverride)
        }
    }

    /// `sendOverride` — инъекция канала для замка (nil — живые пути).
    /// `appActive` — квитанция «прочитано» рождается ТОЛЬКО у активного
    /// приложения (поле 13.08, build 19: чат, оставленный открытым на
    /// заблокированном телефоне, квитировал входящие на ПРИХОД —
    /// отправитель видел «прочитано», хотя человек спал).
    func sendReadReceipts(contactID: String?,
                          appActive: Bool =
                            UIApplication.shared.applicationState == .active,
                          sendOverride: ((_ packet: [UInt8],
                                          _ completion: @escaping @Sendable (Bool) -> Void)
                                         -> Void)? = nil) {
        guard Self.readReceiptsEnabled else { return }
        guard appActive else { return }
        // чат открыт — он должник, пока всё не заквитировано (ретрай
        // насосом; раньше потерянная квитанция ждала следующего
        // ОТКРЫТИЯ чата — «жёлтый не снимается»)
        receiptDebtors.insert(Self.debtorKey(contactID))
        // отметка уходит по радио и/или прямому пути «рядом» (07.08) —
        // с учётом ручной маски (галка глушит и служебные пакеты)
        let channels = Self.serviceChannels(
            radioReady: transportKind == "mesh", nearbyReady: nearbyReady,
            relayReady: RelayTransport.shared.active,
            loraAllowed: TransportMode.loraAllowed,
            bleAllowed: TransportMode.bleAllowed)
        guard sendOverride != nil
                || channels.radio || channels.nearby || channels.relay
        else { return }
        let unreceipted = HumanChatStore.loadLog(contactID: contactID)
            .filter { $0.kind == .incoming && $0.wireMsgID != nil
                      && $0.readAt == nil }
        // след квитанций (мега-7, 14.08: «первое Привет непрочитано»
        // разбирался вслепую — дневник не знал, ушла ли отметка вообще)
        if !unreceipted.isEmpty, sendOverride == nil {
            TransportDiary.note("[квитанции] шлю \(unreceipted.count) "
                + "отметок (радио:\(channels.radio ? "да" : "нет") "
                + "рядом:\(channels.nearby ? "да" : "нет"))")
        }
        for entry in unreceipted {
            guard let wire = entry.wireMsgID else { continue }
            let packet = Envelope.encodeHeader(
                msgClass: Envelope.classRead, flags: 0,
                msgID: Envelope.newMsgID()) + Envelope.le16(UInt16(wire))
            // Штамп readAt — ТОЛЬКО по подтверждению канала (А3, 09.08:
            // штамп до отправки терял квитанцию навсегда — залп после
            // длинного сообщения конкурировал с ним за канал, потерянные
            // отметки больше не выбирались фильтром readAt == nil, и у
            // отправителя мелкие «прочитанные» стопорились неотмеченными).
            // Не ушла — не штампуем: следующее открытие чата повторит.
            // Приёмная сторона идемпотентна (markRead: readAt != nil —
            // выход), дубликаты безопасны.
            let entryID = entry.id
            let stamp: @Sendable (Bool) -> Void = { [weak self] ok in
                guard ok else { return }
                Task { @MainActor in
                    self?.markEntry(entryID: entryID, contactID: contactID) {
                        if $0.readAt == nil { $0.readAt = Date() }
                    }
                    TransportDiary.note("[квитанции] отметка wire=\(wire) "
                        + "подтверждена каналом")
                    self?.eventCounter += 1
                }
            }
            if let sendOverride {
                sendOverride(packet, stamp)
                continue
            }
            if channels.radio {
                link.send(packet, toHost: peerHost) { ok in stamp(ok) }
            }
            if channels.nearby {
                NearbyTransport.shared.send(packet) { ok in stamp(ok) }
            }
            // Поле 29.09: «прочитано» тоже обязано уметь релей — иначе
            // в форс-«только интернет» вторая отметка не зеленеет
            // (contactID здесь nil только у демо-чата — ему релей ни к чему)
            if channels.relay, let contactID {
                RelayTransport.shared.sendService(packet,
                                                  contactID: contactID) {
                    ok in stamp(ok)
                }
            }
        }
    }

    private static let seenKey = "seen_incoming_msg_ids"

    private func markEntry(entryID: UUID, contactID: String?,
                           _ mutate: (inout ChatEntry) -> Void) {
        var log = HumanChatStore.loadLog(contactID: contactID)
        guard let index = log.firstIndex(where: { $0.id == entryID })
        else { return }
        mutate(&log[index])
        HumanChatStore.saveLog(log, contactID: contactID)
    }
}

/// Копилка подтверждений доставки (замок на клин отдачи узла, 03.08):
/// ack не уходит мгновенно на каждый принятый пакет — во время залпового
/// дренажа это давало шквал записей ToRadio и клинило PhoneAPI узла.
/// Подтверждения копятся и сдаются после окна тишины приёма; бесконечный
/// поток приёма не задерживает их дольше потолка maxHold.
nonisolated struct AckAggregator: Sendable {
    static let quietWindow: TimeInterval = 3
    static let maxHold: TimeInterval = 10
    private var entries: [(id: UInt16, contactID: String?)] = []
    private var firstAt: Date?
    private var lastAt: Date?

    /// Совместимость замков (NearbyFieldFixTests): голые msgID копилки.
    var pending: [UInt16] { entries.map(\.id) }

    /// contactID — чей это ack: релейный путь кладёт подтверждение в
    /// ящик ПАРЫ этого контакта (nil — контакт неизвестен, релей мимо).
    mutating func add(_ id: UInt16, contactID: String? = nil, now: Date) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            // повтор того же msgID: контакт мог доопределиться
            if entries[index].contactID == nil {
                entries[index].contactID = contactID
            }
        } else {
            entries.append((id, contactID))
        }
        if firstAt == nil { firstAt = now }
        lastAt = now
    }

    /// Пары (msgID, contactID) к отправке; пусто — рано (тишина не
    /// наступила). Копилка очищается.
    mutating func takeDueWithContacts(now: Date)
    -> [(id: UInt16, contactID: String?)] {
        guard let first = firstAt, let last = lastAt,
              now.timeIntervalSince(last) >= Self.quietWindow
                || now.timeIntervalSince(first) >= Self.maxHold
        else { return [] }
        let out = entries
        entries = []
        firstAt = nil
        lastAt = nil
        return out
    }

    /// Старый вид — голые msgID (radio/nearby им и живут).
    mutating func takeDue(now: Date) -> [UInt16] {
        takeDueWithContacts(now: now).map(\.id)
    }
}

/// Кольцо недавно принятых msgID — защита от дублей при повторах.
/// msgID 16-битный и общий на эфир: коллизия возможна, но окно в 64
/// последних сообщения делает её маловероятной для LAN-репетиции.
nonisolated struct SeenMsgIDs {
    static let capacity = 64
    private(set) var ids: [Int]

    init(ids: [Int] = []) { self.ids = ids }

    /// true — свежий (кладём в ленту); false — дубль повтора.
    mutating func insert(_ id: UInt16) -> Bool {
        guard !ids.contains(Int(id)) else { return false }
        ids.append(Int(id))
        if ids.count > Self.capacity {
            ids.removeFirst(ids.count - Self.capacity)
        }
        return true
    }
}

/// Сборщик исходов отправки пакетов одного сообщения: все дошли —
/// попытка удалась; хоть один провалился — повтор по бэкоффу.
private nonisolated final class SendTally: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private var done = 0
    private var ok = 0
    private let completion: @Sendable (Bool) -> Void

    init(total: Int, completion: @escaping @Sendable (Bool) -> Void) {
        self.total = max(total, 1)
        self.completion = completion
    }

    func report(_ success: Bool) {
        lock.lock()
        done += 1
        if success { ok += 1 }
        let finished = done == total
        let allOK = ok == total
        lock.unlock()
        if finished { completion(allOK) }
    }
}

/// Curve25519-ключ из сырых байт (хелпер до Identity, чтобы не тянуть
/// CryptoKit в сигнатуры менеджера).
nonisolated func Curve25519KeyFromRaw(_ raw: [UInt8])
throws -> CryptoKit.Curve25519.KeyAgreement.PublicKey {
    try CryptoKit.Curve25519.KeyAgreement.PublicKey(
        rawRepresentation: Data(raw))
}

