import Foundation
import CoreBluetooth

// ============================================================================
// BleLink — BLE как равноправный транспорт (трек «мост к радиоузлу», Ф1).
//
// По эфиру летают ТОЛЬКО готовые envelope-блобы — как в LanLink,
// плейнтекста нет. Обмен телефон↔телефон симметричен: устройство
// одновременно и central (ищет соседей по service UUID), и peripheral
// (отдаёт характеристику приёма). Фрагментация под MTU BLE:
// [tag 1Б][index 1Б][total 1Б][кусок], сборка на приёме; ack/retry —
// те же, что у LAN (DeliveryManager выше этого слоя).
// ============================================================================

nonisolated final class BleLink: NSObject, TransportLink, @unchecked Sendable {

    /// Свой сервис R+M (не Meshtastic — тот в MeshtasticLink).
    static let serviceUUID = CBUUID(
        string: "524D0001-5359-534C-524D-30303153594C")
    /// Характеристика входящих блобов (write without response).
    static let inboxUUID = CBUUID(
        string: "524D0002-5359-534C-524D-30303253594C")

    var onReceive: (@Sendable ([UInt8]) -> Void)?

    private let queue = DispatchQueue(label: "chappe.blelink")
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var inboxCharacteristic: CBMutableCharacteristic?

    // связи central-стороны
    private var discovered: [UUID: CBPeripheral] = [:]
    private var writeTargets: [UUID: CBCharacteristic] = [:]
    private var pendingSends: [(data: [UInt8],
                                completion: @Sendable (Bool) -> Void)] = []

    // сборка входящих фрагментов: tag -> (total, [index: chunk])
    private var assembly: [UInt8: (total: Int, chunks: [Int: [UInt8]])] = [:]
    private var nextTag: UInt8 = 0

    /// Состояние для Dev-экрана.
    private(set) var stateLine = "выключен"
    private(set) var lastRSSI: Int?
    private(set) var peerCount = 0
    /// Число живых соседей изменилось (фаза 1 «рядом», 07.08):
    /// NearbyTransport показывает его и решает, есть ли путь.
    var onPeersChanged: (@Sendable (Int) -> Void)?

    func start() {
        queue.async { [self] in
            // Bluetooth выключен человеком — молчим (полевой дефект 08.08:
            // системный запрос «разрешите Bluetooth» всплывал снова и
            // снова при каждом открытии приложения, потому что оба
            // менеджера по умолчанию показывают power alert). Транспорт
            // «рядом» обязан деградировать тихо: нет радио — нет пути,
            // человек об этом не спрашивается.
            central = CBCentralManager(
                delegate: self, queue: queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
            peripheralManager = CBPeripheralManager(
                delegate: self, queue: queue,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
            stateLine = "включается…"
            startKeepalive()
        }
    }

    func stop() {
        queue.async { [self] in
            central?.stopScan()
            peripheralManager?.stopAdvertising()
            for p in discovered.values {
                central?.cancelPeripheralConnection(p)
            }
            stopKeepalive()
            discovered.removeAll()
            writeTargets.removeAll()
            backlog = BleChunkBacklog()
            confirmLedger.failEverything()   // ожидания — честный false
            central = nil
            peripheralManager = nil
            stateLine = "выключен"
            peerCount = 0
            onPeersChanged?(0)
        }
    }

    /// host для BLE не используется: пакет уходит ВЕЕРОМ всем живым
    /// соседям (фаза 1 «рядом», 07.08) — адресата выбирает не транспорт,
    /// а конверт: получатель узнаёт своё по dst (dstIsForMe), остальные
    /// молча отбрасывают. Так в эфире нет ни адресов, ни рукопожатий.
    func send(_ packet: [UInt8], toHost host: String,
              completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let peers = writablePeers()
            guard !peers.isEmpty else {
                // некому писать — отдать в ожидание: подключимся — дошлём
                pendingSends.append((packet, completion))
                if pendingSends.count > 32 {
                    pendingSends.removeFirst().completion(false)
                }
                return
            }
            // успех попытки = ушло хоть одному при живом соединении
            let tally = BleFanTally(total: peers.count, completion: completion)
            for (peripheral, characteristic) in peers {
                writeFragments(packet, to: peripheral, over: characteristic) { ok in
                    tally.report(ok)
                }
            }
        }
    }

    private func writablePeers() -> [(CBPeripheral, CBCharacteristic)] {
        writeTargets.compactMap { id, characteristic in
            guard let p = discovered[id], p.state == .connected else {
                return nil
            }
            return (p, characteristic)
        }
    }

    private func writeFragments(_ packet: [UInt8], to peripheral: CBPeripheral,
                                over characteristic: CBCharacteristic,
                                completion: @escaping @Sendable (Bool) -> Void) {
        let mtu = max(peripheral.maximumWriteValueLength(
            for: .withoutResponse) - 3, 20)
        let tag = nextTag &+ 1
        nextTag = tag
        let chunks = Self.fragment(packet, mtu: mtu, tag: tag)
        // Противодавление (полевой прогон 08.08: сообщение из 3 пакетов
        // не дошло, короткие доходили): залп writeValue .withoutResponse
        // без проверки canSendWriteWithoutResponse молча теряет куски в
        // переполненной очереди CoreBluetooth. Куски идут через backlog:
        // пишем, пока канал принимает, остаток доливает
        // peripheralIsReady(toSendWriteWithoutResponse:).
        //
        // Честность успеха (полевое 13.08: «передан по nearby» каждые
        // 60 с без единого ack — соединение числилось connected, но было
        // мертво, записи молча тонули): ПОСЛЕДНИЙ кусок пакета уходит
        // .withResponse, и успех отдаётся ТОЛЬКО по didWriteValueFor —
        // «успех подтверждается тем событием, которое его означает».
        // Провал/обрыв — честный false, повтор дошлёт насос.
        confirmLedger.register(peer: peripheral.identifier,
                               completion: completion)
        backlog.add(chunks, confirmLast: true, for: peripheral.identifier)
        drainBacklog(for: peripheral, over: characteristic)
    }

    /// Незаписанные куски по соседям (переполнение канала — не потеря).
    private var backlog = BleChunkBacklog()

    // ── Keepalive (мега-9, 14.08): iOS рвёт простаивающее GATT-
    // соединение каждые ~66 с (вечерний дневник: соседей 1→0→реконнект
    // весь вечер) — сообщения ездили пачками в короткие живые окна.
    // Раз в 20 с в каждое живое соединение пишется байт-пульс
    // (.withoutResponse); приёмный ассемблер отбрасывает его по
    // построению (кадр короче 3 байт). Замок: keepaliveIsInvisible.
    static let keepaliveInterval: TimeInterval = 20
    static let keepaliveFrame: [UInt8] = [0xA5]
    private var keepaliveTimer: DispatchSourceTimer?

    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepaliveInterval,
                       repeating: Self.keepaliveInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for (peripheral, characteristic) in self.writablePeers()
            where peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(Data(Self.keepaliveFrame),
                                      for: characteristic,
                                      type: .withoutResponse)
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }
    /// Ожидающие подтверждения последних кусков (по didWriteValueFor).
    private var confirmLedger = BleConfirmLedger()

    private func drainBacklog(for peripheral: CBPeripheral,
                              over characteristic: CBCharacteristic) {
        backlog.drain(
            for: peripheral.identifier,
            canSend: { peripheral.state == .connected
                && peripheral.canSendWriteWithoutResponse },
            write: { chunk in
                peripheral.writeValue(Data(chunk), for: characteristic,
                                      type: .withoutResponse)
            },
            // Подтверждаемый кусок: у withResponse своя очередь
            // CoreBluetooth, canSend-гейт к ней не относится. Никаких
            // локальных «провалов» здесь: ответы паруются с ожиданиями
            // строго FIFO через didWriteValueFor, а обрыв проваливает
            // всё скопом в didDisconnect — иначе провал одного куска
            // мог бы выстрелить completion ЧУЖОГО пакета.
            writeConfirmed: { chunk in
                peripheral.writeValue(Data(chunk), for: characteristic,
                                      type: .withResponse)
            })
    }


    /// Чистая фрагментация: [tag][index][total][кусок] — тестируемо.
    nonisolated static func fragment(_ packet: [UInt8], mtu: Int,
                                     tag: UInt8) -> [[UInt8]] {
        let chunkSize = max(mtu - 3, 1)
        var out: [[UInt8]] = []
        var i = 0
        let total = (packet.count + chunkSize - 1) / chunkSize
        while i < packet.count {
            let end = min(i + chunkSize, packet.count)
            out.append([tag, UInt8(out.count), UInt8(min(total, 255))]
                       + packet[i..<end])
            i = end
        }
        return out.isEmpty ? [[tag, 0, 1]] : out
    }

    /// Чистая сборка одного фрагмента; вернёт цельный блоб при полноте.
    nonisolated static func assemble(
        into assembly: inout [UInt8: (total: Int, chunks: [Int: [UInt8]])],
        fragment: [UInt8]) -> [UInt8]? {
        guard fragment.count >= 3 else { return nil }
        let tag = fragment[0]
        let index = Int(fragment[1])
        let total = Int(fragment[2])
        guard total >= 1, index < total else { return nil }
        var record = assembly[tag] ?? (total, [:])
        guard record.total == total else {
            assembly[tag] = (total, [index: Array(fragment.dropFirst(3))])
            return nil
        }
        record.chunks[index] = Array(fragment.dropFirst(3))
        assembly[tag] = record
        guard record.chunks.count == total else { return nil }
        assembly[tag] = nil
        return (0..<total).compactMap { record.chunks[$0] }.flatMap { $0 }
    }

    private func flushPending() {
        guard !pendingSends.isEmpty, !writablePeers().isEmpty else { return }
        let sends = pendingSends
        pendingSends.removeAll()
        for pending in sends {
            send(pending.data, toHost: "", completion: pending.completion)
        }
    }
}

/// Сборщик исходов веера: completion один раз, когда отчитались все;
/// успех — если ушло хоть одному (образец: SendTally выше по слою).
private nonisolated final class BleFanTally: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private let completion: @Sendable (Bool) -> Void
    private var reported = 0
    private var anyOK = false
    init(total: Int, completion: @escaping @Sendable (Bool) -> Void) {
        self.total = total
        self.completion = completion
    }
    func report(_ ok: Bool) {
        lock.lock()
        reported += 1
        anyOK = anyOK || ok
        let fire = reported == total
        let outcome = anyOK
        lock.unlock()
        if fire { completion(outcome) }
    }
}

// MARK: - Central: поиск соседей и запись им

extension BleLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.serviceUUID])
            stateLine = "ищу собеседников…"
            TransportDiary.note("[рядом] скан запущен")
        } else {
            stateLine = "Bluetooth недоступен (\(central.state.rawValue))"
            // пульс причины (правило 3): 5 = нет разрешения, 4 = выключен
            TransportDiary.note(
                "[рядом] скан не запущен: состояние BLE \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        lastRSSI = RSSI.intValue
        guard discovered[peripheral.identifier] == nil else { return }
        discovered[peripheral.identifier] = peripheral
        peripheral.delegate = self
        TransportDiary.note("[рядом] сосед найден, подключаюсь (RSSI \(RSSI.intValue))")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        discovered[peripheral.identifier] = nil
        writeTargets[peripheral.identifier] = nil
        backlog.forget(peripheral.identifier)   // повторы дошлют выше
        // ожидания подтверждений — честный false (полевое 13.08:
        // молчание мёртвого соединения выдавалось за успех)
        confirmLedger.failAll(peer: peripheral.identifier)
        peerCount = writeTargets.count
        stateLine = peerCount > 0 ? "на связи: \(peerCount)" : "ищу собеседников…"
        onPeersChanged?(peerCount)
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        for service in peripheral.services ?? []
        where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.inboxUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? []
        where characteristic.uuid == Self.inboxUUID {
            writeTargets[peripheral.identifier] = characteristic
            peerCount = writeTargets.count
            stateLine = "на связи: \(peerCount)"
            onPeersChanged?(peerCount)
            flushPending()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didReadRSSI RSSI: NSNumber, error: Error?) {
        lastRSSI = RSSI.intValue
    }

    /// Очередь CoreBluetooth снова принимает write-without-response —
    /// долить куски, ждавшие канала (вторая половина противодавления;
    /// сигнатура сверена по SDK: peripheralIsReadyToSendWriteWithoutResponse:).
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let characteristic = writeTargets[peripheral.identifier] else {
            backlog.forget(peripheral.identifier)
            return
        }
        drainBacklog(for: peripheral, over: characteristic)
    }

    /// Ответ на .withResponse-запись последнего куска — единственное
    /// событие, означающее «сосед принял пакет» на уровне канала
    /// (сигнатура сверена по SDK: didWriteValueForCharacteristic:error:).
    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            TransportDiary.note("[рядом] запись не подтверждена: "
                                + error.localizedDescription)
        }
        confirmLedger.confirmOldest(peer: peripheral.identifier,
                                    ok: error == nil)
        // дренаж мог ждать окна — продолжить
        if let characteristic = writeTargets[peripheral.identifier] {
            drainBacklog(for: peripheral, over: characteristic)
        }
    }
}

/// Незаписанные BLE-куски по соседям. Чистая структура — её дисциплина
/// (писать только пока канал принимает, ничего не терять и не путать
/// порядок) закрыта замком в NearbyFieldFixTests.
nonisolated struct BleChunkBacklog {
    /// Потолок на соседа: ~64 КБ при MTU 180 — дальше честнее уронить
    /// старое, чем расти без края (повторы дошлют уровнем выше).
    static let capacity = 384

    /// Кусок очереди: confirm — писать .withResponse (последний кусок
    /// пакета, несёт честное подтверждение записи; полевое 13.08).
    struct Chunk {
        let bytes: [UInt8]
        let confirm: Bool
    }

    private var byPeer: [UUID: [Chunk]] = [:]
    /// Сколько кусков выброшено потолком (Dev-диагностика).
    private(set) var dropped = 0

    mutating func add(_ chunks: [[UInt8]], for peer: UUID) {
        add(chunks, confirmLast: false, for: peer)
    }

    mutating func add(_ chunks: [[UInt8]], confirmLast: Bool,
                      for peer: UUID) {
        var queue = byPeer[peer] ?? []
        for (i, bytes) in chunks.enumerated() {
            queue.append(Chunk(bytes: bytes,
                               confirm: confirmLast && i == chunks.count - 1))
        }
        if queue.count > Self.capacity {
            dropped += queue.count - Self.capacity
            queue.removeFirst(queue.count - Self.capacity)
        }
        byPeer[peer] = queue
    }

    /// Пишет по одному куску, пока canSend позволяет; остаток ждёт
    /// следующего drain (peripheralIsReady).
    mutating func drain(for peer: UUID,
                        canSend: () -> Bool,
                        write: ([UInt8]) -> Void) {
        drain(for: peer, canSend: canSend, write: write,
              writeConfirmed: write)
    }

    /// Полный вариант: подтверждаемые куски идут отдельным писателем
    /// (.withResponse — у него своя очередь, canSend его не гейтит).
    mutating func drain(for peer: UUID,
                        canSend: () -> Bool,
                        write: ([UInt8]) -> Void,
                        writeConfirmed: ([UInt8]) -> Void) {
        var queue = byPeer[peer] ?? []
        while let first = queue.first {
            if first.confirm {
                writeConfirmed(first.bytes)
                queue.removeFirst()
                continue
            }
            guard canSend() else { break }
            write(first.bytes)
            queue.removeFirst()
        }
        byPeer[peer] = queue.isEmpty ? nil : queue
    }

    mutating func forget(_ peer: UUID) { byPeer[peer] = nil }

    func pendingCount(for peer: UUID) -> Int { byPeer[peer]?.count ?? 0 }
}

/// Ожидающие подтверждения записи (честность «передан по nearby»,
/// полевое 13.08): последний кусок пакета уходит .withResponse, и
/// completion пакета стреляет только по didWriteValueFor. Порядок FIFO
/// на соседа — ATT-запросы отвечаются последовательно. Обрыв соединения
/// проваливает ВСЕ ожидания соседа честным false (повторы дошлёт насос).
nonisolated struct BleConfirmLedger {
    private var byPeer: [UUID: [@Sendable (Bool) -> Void]] = [:]

    mutating func register(peer: UUID,
                           completion: @escaping @Sendable (Bool) -> Void) {
        byPeer[peer, default: []].append(completion)
    }

    /// Ответ на старейшую запись соседа; вернувшийся completion зовёт
    /// вызывающий (не внутри мутации — completion может прийти в акторе).
    mutating func confirmOldest(peer: UUID, ok: Bool) {
        guard var queue = byPeer[peer], !queue.isEmpty else { return }
        let completion = queue.removeFirst()
        byPeer[peer] = queue.isEmpty ? nil : queue
        completion(ok)
    }

    /// Сосед оборвался — все его ожидания проваливаются честно.
    mutating func failAll(peer: UUID) {
        let completions = byPeer[peer] ?? []
        byPeer[peer] = nil
        for completion in completions { completion(false) }
    }

    /// Полная остановка канала — провалить всё по всем соседям.
    mutating func failEverything() {
        let all = byPeer.values.flatMap { $0 }
        byPeer = [:]
        for completion in all { completion(false) }
    }

    func pendingCount(peer: UUID) -> Int { byPeer[peer]?.count ?? 0 }
}

// MARK: - Peripheral: приём блобов от соседей

extension BleLink: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        guard manager.state == .poweredOn else {
            TransportDiary.note(
                "[рядом] реклама не запущена: состояние BLE \(manager.state.rawValue)")
            return
        }
        TransportDiary.note("[рядом] реклама запущена")
        let characteristic = CBMutableCharacteristic(
            type: Self.inboxUUID,
            properties: [.writeWithoutResponse, .write],
            value: nil, permissions: [.writeable])
        inboxCharacteristic = characteristic
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        manager.removeAllServices()
        manager.add(service)
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
        ])
    }

    func peripheralManager(_ manager: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let data = request.value else { continue }
            if let whole = Self.assemble(into: &assembly,
                                         fragment: Array(data)) {
                onReceive?(whole)
            }
            if request.characteristic.properties.contains(.write) {
                manager.respond(to: request, withResult: .success)
            }
        }
    }
}
