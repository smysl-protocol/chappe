import Foundation
import CoreBluetooth

// ============================================================================
// MeshtasticLink — мост к радиоузлу (трек BLE, Ф3).
//
// Наш envelope едет ВНУТРИ meshtastic-пакета непрозрачными байтами:
// MeshPacket.decoded { portnum = PRIVATE_APP(256), payload = блоб }.
// Шифрование канала узла нас не касается — наше E2E остаётся нашим.
//
// GATT (сверено по meshtastic.org/docs/development/device/client-api,
// 30.07.2026; FromRadio UUID «2c55e69e…» — актуальный, старый 8ba2bcc2
// устарел): сервис 6ba1b218-15a8-461f-9fa8-5dcae273eafd,
// ToRadio f75c76d2… (write), FromRadio 2c55e69e… (read до пустого),
// FromNum ed9da18c… (notify о новых пакетах).
//
// Регион (SG_923) и лимиты — в конфиге mesh_config.json, не в коде.
// Airtime-бюджет: очередь не выжирает дьюти-цикл — при превышении
// сообщения ждут с честным статусом. Приоритет: SOS > исходящее.
// ============================================================================

nonisolated struct MeshConfig: Decodable, Sendable {
    var region: String = "SG_923"
    var modemPreset: String = "LongFast"
    /// Полезная нагрузка meshtastic-пакета для нашего блоба.
    var payloadLimit: Int = 200
    /// Бюджет эфирного времени, секунд на скользящий час.
    var airtimeBudgetSecondsPerHour: Double = 36
    /// Оценка скорости пресета (байт/с эфира) для расчёта airtime.
    /// LONG_FAST = SF11/BW250/CR4:5 → ~134 Б/с по формуле Semtech;
    /// прежние 190 Б/с занижали расход и бюджет тратился быстрее, чем
    /// считался (замер на живом железе 02.08).
    var presetBytesPerSecond: Double = 134
    /// Имя BLE-периферии узла; пусто — берём первый найденный сервис
    /// (мок и живой узел переключаются ЭТОЙ настройкой, не пересборкой).
    var peripheralName: String = ""

    static func load() -> MeshConfig {
        guard let url = Bundle.main.url(forResource: "mesh_config",
                                        withExtension: "json")
                ?? Bundle.main.url(forResource: "mesh_config",
                                   withExtension: "json",
                                   subdirectory: "sophie_kb"),
              let cfg = try? JSONDecoder().decode(
                  MeshConfig.self, from: Data(contentsOf: url))
        else { return overridden(MeshConfig()) }
        return overridden(cfg)
    }

    /// Переключение мок ↔ живой узел — НАСТРОЙКОЙ (Dev-экран),
    /// не пересборкой: UserDefaults сильнее бандл-конфига.
    private static func overridden(_ base: MeshConfig) -> MeshConfig {
        var cfg = base
        if let name = UserDefaults.standard.string(
            forKey: "mesh_peripheral_name"), !name.isEmpty {
            cfg.peripheralName = name
        }
        return cfg
    }
}

// MARK: - Мини-протобаф: ровно тот субсет, что нужен ToRadio/FromRadio

nonisolated enum MiniProto {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            out.append(byte | (v != 0 ? 0x80 : 0))
        } while v != 0
        return out
    }

    static func key(_ field: Int, wire: Int) -> [UInt8] {
        varint(UInt64(field << 3 | wire))
    }

    static func lenField(_ field: Int, _ data: [UInt8]) -> [UInt8] {
        key(field, wire: 2) + varint(UInt64(data.count)) + data
    }

    /// fixed32 (wire 5) — для MeshPacket.from/to/id. Их нельзя писать
    /// varint'ом: узел не разберёт ToRadio и МОЛЧА выбросит пакет,
    /// а BLE-запись при этом успешна — приложение покажет «отправлено».
    /// Поймано на живом эфире 02.08: с varint не ушло ни одного пакета.
    static func fix32Field(_ field: Int, _ value: UInt32) -> [UInt8] {
        key(field, wire: 5) + [UInt8(value & 0xFF),
                               UInt8((value >> 8) & 0xFF),
                               UInt8((value >> 16) & 0xFF),
                               UInt8(value >> 24)]
    }

    static func varField(_ field: Int, _ value: UInt64) -> [UInt8] {
        value == 0 ? [] : key(field, wire: 0) + varint(value)
    }

    /// ToRadio{ packet=1: MeshPacket{ to=2, decoded=4: Data{ portnum=1,
    /// payload=2 }, id=6, want_ack=10 } } (номера полей — mesh.proto,
    /// сверено 30.07.2026).
    static func toRadio(payload: [UInt8], packetID: UInt32,
                        portnum: UInt64 = 256,
                        to destination: UInt32 = 0xFFFF_FFFF) -> [UInt8] {
        let dataMsg = key(1, wire: 0) + varint(portnum)
                    + lenField(2, payload)
        // to и id — fixed32 по mesh.proto (сверено с первоисточником
        // 02.08; до этого писались varint'ом и узел молча их отбрасывал)
        let mesh = fix32Field(2, destination)
                 + lenField(4, dataMsg)
                 + fix32Field(6, packetID)
                 + varField(10, 1)
        return lenField(1, mesh)
    }

    /// Разбор FromRadio: ищем packet=2 → decoded=4 → (portnum, payload).
    static func fromRadioPayload(_ bytes: [UInt8])
    -> (portnum: UInt64, payload: [UInt8])? {
        guard let mesh = fields(bytes)[2]?.first else { return nil }
        guard let decoded = fields(mesh)[4]?.first else { return nil }
        let f = fields(decoded)
        let portnum = f[1]?.first.flatMap { readVarint($0) } ?? 0
        guard let payload = f[2]?.first else { return nil }
        return (portnum, payload)
    }

    /// Грубый разбор: field -> [значения] (len-поля — содержимое,
    /// varint-поля — байты varint).
    static func fields(_ bytes: [UInt8]) -> [Int: [[UInt8]]] {
        var out: [Int: [[UInt8]]] = [:]
        var i = 0
        while i < bytes.count {
            guard let (keyVal, keyLen) = readVarintAt(bytes, i) else { break }
            i += keyLen
            let field = Int(keyVal >> 3)
            let wire = Int(keyVal & 7)
            switch wire {
            case 0:
                guard let (v, l) = readVarintAt(bytes, i) else { return out }
                out[field, default: []].append(varint(v))
                i += l
            case 2:
                guard let (len, l) = readVarintAt(bytes, i) else { return out }
                i += l
                guard i + Int(len) <= bytes.count else { return out }
                out[field, default: []].append(
                    Array(bytes[i..<i + Int(len)]))
                i += Int(len)
            case 5:
                // fixed32 РАНЬШЕ молча пропускался — поля from/to/id
                // были невидимы разбору и тестам (02.08)
                guard i + 4 <= bytes.count else { return out }
                out[field, default: []].append(Array(bytes[i..<i + 4]))
                i += 4
            case 1: i += 8
            default: return out
            }
        }
        return out
    }

    static func readVarint(_ bytes: [UInt8]) -> UInt64? {
        readVarintAt(bytes, 0)?.0
    }

    static func readVarintAt(_ bytes: [UInt8], _ at: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = at
        while i < bytes.count {
            let b = bytes[i]
            value |= UInt64(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { return (value, i - at) }
            shift += 7
        }
        return nil
    }
}

// MARK: - Учёт эфирного времени и приоритетная очередь

nonisolated struct AirtimeBudget: Sendable {
    var budgetPerHour: Double
    var bytesPerSecond: Double
    private(set) var spent: [(at: Date, seconds: Double)] = []

    init(config: MeshConfig) {
        budgetPerHour = config.airtimeBudgetSecondsPerHour
        bytesPerSecond = config.presetBytesPerSecond
    }

    func airtime(bytes: Int) -> Double {
        Double(bytes) / max(bytesPerSecond, 1) + 0.15   // преамбула
    }

    mutating func canSend(bytes: Int, now: Date = Date()) -> Bool {
        spent.removeAll { now.timeIntervalSince($0.at) > 3600 }
        let used = spent.reduce(0) { $0 + $1.seconds }
        return used + airtime(bytes: bytes) <= budgetPerHour
    }

    mutating func record(bytes: Int, now: Date = Date()) {
        spent.append((now, airtime(bytes: bytes)))
    }
}

// MARK: - Дисциплина записи (замок на клин отдачи узла, 03.08)

/// «Сначала дочитать, потом писать»: пока узел отдаёт свою очередь
/// (FromRadio возвращает данные), записи ToRadio ждут. Шквал записей
/// во время дренажа трижды за день клинил PhoneAPI узла до разрыва BLE
/// (docs/reports/reception_diagnosis_2026-08-03.md).
nonisolated struct DrainGate: Sendable {
    /// Ответ на чтение мог потеряться — ворота не имеют права запереть
    /// запись навсегда («тишина не есть отказ; у наблюдателя пульс»).
    static let stallTimeout: TimeInterval = 10
    private var draining = false
    private var lastActivityAt: Date?

    mutating func noteReadRequested(now: Date) {
        draining = true
        lastActivityAt = now
    }

    mutating func noteData(now: Date) {
        lastActivityAt = now
    }

    mutating func noteEmptyRead() {
        draining = false
    }

    func canWrite(now: Date) -> Bool {
        guard draining, let at = lastActivityAt else { return true }
        return now.timeIntervalSince(at) > Self.stallTimeout
    }
}

/// Темп записей в ToRadio: не чаще одной в minGap. Узел передаёт LoRa
/// ~1 с на пакет (SF11) — писать быстрее бессмысленно, а залп записей
/// провоцирует клин и глушит его приёмник.
nonisolated struct WritePacer: Sendable {
    static let minGap: TimeInterval = 1.0
    private var nextSlot = Date.distantPast

    func delayUntilFree(now: Date) -> TimeInterval {
        max(0, nextSlot.timeIntervalSince(now))
    }

    mutating func noteWrite(now: Date) {
        nextSlot = max(now, nextSlot).addingTimeInterval(Self.minGap)
    }
}

/// Детектор клина отдачи узла («тишина не есть работа», 03.08):
/// счётчик FromNum растёт, а данных из FromRadio нет дольше dataGrace —
/// узел копит пакеты и не отдаёт. Отдельный вердикт — узел вовсе
/// перестал отвечать на пульс-чтения FromNum при живом соединении.
nonisolated struct StuckLinkDetector: Sendable {
    enum Verdict: Equatable {
        case queueStuck      // пакеты копятся, отдача стоит
        case unresponsive    // чтения без ответа несколько пульсов подряд
    }

    /// Notify → чтение → данные занимает секунды; больше — уже клин.
    static let dataGrace: TimeInterval = 12
    static let unansweredPulsesLimit = 3

    private var lastValue: UInt32?
    private var advanceAt: Date?
    private var lastDataAt: Date?
    private var unansweredPulses = 0

    mutating func notePulseSent(now: Date) {
        unansweredPulses += 1
    }

    mutating func noteFromNum(_ value: UInt32, now: Date) {
        unansweredPulses = 0
        defer { lastValue = value }
        guard let known = lastValue, value != known else { return }
        advanceAt = now
    }

    mutating func noteData(now: Date) {
        lastDataAt = now
    }

    func verdict(now: Date) -> Verdict? {
        if unansweredPulses >= Self.unansweredPulsesLimit {
            return .unresponsive
        }
        if let advanceAt,
           lastDataAt ?? .distantPast < advanceAt,
           now.timeIntervalSince(advanceAt) > Self.dataGrace {
            return .queueStuck
        }
        return nil
    }
}

// MARK: - Шов тестируемости (решение владельца 03.08)
//
// Делегатная проводка CoreBluetooth была слепой зоной ~250 строк: оба
// бага реставрации и клин отдачи узла 03.08 жили именно в ней и были
// невидимы всем тестам (docs/reports/transport_tests_audit_2026-08-03.md,
// раздел 4). Протоколы прячут конкретные CBPeripheral/CBCentralManager:
// логика решений (методы-события ниже) зовёт только протоколы, а тест
// подставляет двойника и проверяет ЖУРНАЛ КОМАНД (NodeLinkSeamTests).

/// Периферия узла глазами транспорта. CBPeripheral соответствует
/// протоколу «как есть»: имена и сигнатуры совпадают один в один,
/// двойник в тестах создаёт CBMutableService/CBMutableCharacteristic.
nonisolated protocol NodePeripheralLink: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    var state: CBPeripheralState { get }
    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?,
                                 for service: CBService)
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic)
    func readValue(for characteristic: CBCharacteristic)
    func writeValue(_ data: Data, for characteristic: CBCharacteristic,
                    type: CBCharacteristicWriteType)
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
}

nonisolated extension CBPeripheral: NodePeripheralLink {}

/// Центральный менеджер глазами транспорта.
nonisolated protocol NodeCentralLink: AnyObject {
    var state: CBManagerState { get }
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?)
    func stopScan()
    func connect(_ peripheral: NodePeripheralLink)
    func cancelPeripheralConnection(_ peripheral: NodePeripheralLink)
    /// Имя отличается от retrieveConnectedPeripherals НАМЕРЕННО:
    /// одинаковое имя с другим типом результата сделало бы вызовы
    /// оригинала на живом CBCentralManager неоднозначными (NodeProbe
    /// зовёт оригинал напрямую).
    func retrieveConnectedNodes(withServices serviceUUIDs: [CBUUID])
        -> [NodePeripheralLink]
}

nonisolated extension CBCentralManager: NodeCentralLink {
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?) {
        scanForPeripherals(withServices: serviceUUIDs, options: nil)
    }
    func connect(_ peripheral: NodePeripheralLink) {
        guard let p = peripheral as? CBPeripheral else { return }
        connect(p, options: nil)
    }
    func cancelPeripheralConnection(_ peripheral: NodePeripheralLink) {
        guard let p = peripheral as? CBPeripheral else { return }
        cancelPeripheralConnection(p)
    }
    func retrieveConnectedNodes(withServices serviceUUIDs: [CBUUID])
        -> [NodePeripheralLink] {
        retrieveConnectedPeripherals(withServices: serviceUUIDs)
    }
}

nonisolated final class MeshtasticLink: NSObject, TransportLink,
                                        @unchecked Sendable {
    var onReceive: (@Sendable ([UInt8]) -> Void)?

    let config: MeshConfig
    /// Внутренняя очередь линка. Доступна тестам шва: события ядра
    /// подаются строго через неё (queue.sync), как их подаёт и живой
    /// CoreBluetooth-стек, созданный с этой очередью.
    let queue = DispatchQueue(label: "chappe.meshlink")
    private var central: NodeCentralLink?
    private var node: NodePeripheralLink?
    private var toRadio: CBCharacteristic?
    private var fromRadio: CBCharacteristic?
    private var fromNum: CBCharacteristic?
    private var packetCounter: UInt32 = UInt32.random(in: 1..<0xFFFF)
    private var airtime: AirtimeBudget
    private var assembly: [UInt8: (total: Int, chunks: [Int: [UInt8]])] = [:]
    private var sendTag: UInt8 = 0
    /// Счётчик отказов записи в узел — раньше они терялись молча
    /// (радиотест 02.08): «отправлено» показывалось, а байты до узла
    /// не доезжали.
    private(set) var writeFailures = 0
    /// Сколько отправок отклонено из-за забитой очереди (видно в Dev).
    private(set) var droppedByBacklog = 0
    /// Имя узла, к которому реально подключён транспорт (видно в Dev).
    private(set) var attachedNodeName: String?

    /// Дедуп радио-строк дневника (13.08): пульс-чтения каждые 2 с
    /// писали fromNum + «пусто — дочитано» ~3 строки/с, 64-КБ хвост
    /// съедал историю за ~2 часа — окно полевого теста и пульсы
    /// уведомлений вырезались обрезкой. Дневник флудом глушить нельзя:
    /// наблюдатель, кричащий без события, хуже молчащего.
    private var diaryDedup = RadioDiaryDedup()

    /// Живые факты узла из конфиг-дампа рабочего линка (13.08): раньше
    /// факты умел собирать только NodeProbe, и в рабочей фазе .yielded
    /// экран показывал «Имя —, Страна —» при живом радиоканале.
    private var factsParser = NodeFactsParser()
    private(set) var liveFacts = NodeProbe.NodeFacts()

    /// Очередь с приоритетами: SOS > исходящее > остальное.
    private var waiting: [(priority: Int, packet: [UInt8],
                           completion: @Sendable (Bool) -> Void)] = []
    private(set) var stateLine = "выключен"

    /// Живость линка к узлу — для решений маршрутизации (блок 1, 10.08).
    /// «Сконфигурирован» ≠ «жив»: полевая потеря 09.08 — узел вне зоны,
    /// а насос лил в него попытки до похорон сообщения при живом
    /// интернете. Пишется на queue, читается с MainActor — под замком.
    private let linkUpLock = NSLock()
    private var _linkUp = false
    var isLinkUp: Bool {
        linkUpLock.lock()
        defer { linkUpLock.unlock() }
        return _linkUp
    }
    private func setLinkUp(_ up: Bool) {
        linkUpLock.lock()
        _linkUp = up
        linkUpLock.unlock()
    }
    private(set) var queuedForAirtime = 0

    /// Дисциплина записи (замок на клин отдачи узла, 03.08):
    /// сначала дочитать очередь узла, потом писать — и писать с темпом.
    private var gate = DrainGate()
    private var pacer = WritePacer()
    private var drainScheduled = false

    /// Пульс наблюдателя (правило 03.08: «тишина не есть отказ;
    /// наблюдатель обязан иметь пульс»): раз в pulseInterval читаем
    /// FromNum. Заодно это страховка от потерянных notify — чтение
    /// счётчика само дёргает дренаж, если узел что-то накопил.
    static let pulseInterval: TimeInterval = 15
    private var detector = StuckLinkDetector()
    private var pulseScheduled = false
    private var lastWarning: String?
    /// Вердикт детектора наружу (DeliveryManager показывает баннер).
    var onLinkWarning: (@Sendable (String?) -> Void)?

    private func schedulePulse() {
        guard !pulseScheduled else { return }
        pulseScheduled = true
        queue.asyncAfter(deadline: .now() + Self.pulseInterval) { [weak self] in
            guard let self else { return }
            self.pulseScheduled = false
            self.pulse()
        }
    }

    private func pulse() {
        guard let node, node.state == .connected, let fromNum else { return }
        detector.notePulseSent(now: Date())
        node.readValue(for: fromNum)
        evaluateLink()
        schedulePulse()
    }

    private func evaluateLink() {
        let warning: String?
        switch detector.verdict(now: Date()) {
        case .queueStuck:
            warning = "Устройство копит пакеты, но не отдаёт их приложению. "
                    + "Выключите и включите Bluetooth в Пункте управления."
        case .unresponsive:
            warning = "Устройство перестало отвечать приложению. "
                    + "Выключите и включите Bluetooth в Пункте управления."
        case nil:
            warning = nil
        }
        guard warning != lastWarning else { return }
        lastWarning = warning
        TransportDiary.note("детектор: \(warning ?? "тревога снята")")
        if let warning { stateLine = "⚠︎ " + warning }
        onLinkWarning?(warning)
    }

    /// Один отложенный прогон очереди, без наслоения таймеров.
    private func scheduleDrain(after delay: TimeInterval) {
        guard !drainScheduled else { return }
        drainScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.drainScheduled = false
            self?.drainQueue()
        }
    }

    static let serviceUUID = CBUUID(
        string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    static let toRadioUUID = CBUUID(
        string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    static let fromRadioUUID = CBUUID(
        string: "2c55e69e-4993-11ed-b878-0242ac120002")
    static let fromNumUUID = CBUUID(
        string: "ed9da18c-a800-4f66-a670-aa7547e34453")

    override init() {
        config = MeshConfig.load()
        airtime = AirtimeBudget(config: config)
        super.init()
    }

    /// Идентификатор реставрации: с ним iOS возвращает НАШ же
    /// центральный менеджер вместе с подключённым узлом после того,
    /// как приложение было выгружено в фоне (03.08 — вместе с
    /// bluetooth-central в UIBackgroundModes). Без него фоновый режим
    /// бесполезен: система разбудит процесс, а узла у него не будет.
    static let restoreIdentifier = "com.chappe.app.mesh.central"

    /// Фабрика центрального менеджера (шов 03.08): боевая создаёт
    /// CBCentralManager с restore-идентификатором, тест отдаёт
    /// двойника. Ядро-автомат не знает, кто перед ним.
    var makeCentral: (_ link: MeshtasticLink, _ queue: DispatchQueue)
        -> NodeCentralLink = { link, queue in
            CBCentralManager(
                delegate: link, queue: queue,
                options: [CBCentralManagerOptionRestoreIdentifierKey:
                            MeshtasticLink.restoreIdentifier])
        }

    func start() {
        queue.async { [self] in
            central = makeCentral(self, queue)
            stateLine = "ищу радио…"
        }
    }

    func stop() {
        queue.async { [self] in
            setLinkUp(false)
            if let node { central?.cancelPeripheralConnection(node) }
            central?.stopScan()
            central = nil
            node = nil
            stateLine = "выключен"
        }
    }

    /// Приоритет envelope-пакета: SOS(класс 0x1) > остальные.
    nonisolated static func priority(of packet: [UInt8]) -> Int {
        guard let first = packet.first else { return 2 }
        return (first & 0x0F) == 0x1 ? 0 : 1
    }

    /// Потолок очереди передачи. Живой прогон 02.08 показал 6291
    /// запись: насос повторов докладывает пакеты каждые 2 с, а очередь
    /// не отдаёт их, пока занят эфир (дьюти-цикл) — рост без предела.
    static let maxWaiting = 64

    func send(_ packet: [UInt8], toHost host: String,
              completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            // мёртвый линк отвечает отказом СРАЗУ, а не молчанием
            // (правило 3): раньше пакет ложился в waiting, completion
            // висел, а насос тикал попытки в никуда
            guard isLinkUp else {
                completion(false)
                return
            }
            // тот же пакет уже ждёт отправки — не плодим копии
            // (повтор придёт снова, когда освободится эфир)
            if waiting.contains(where: { $0.packet == packet }) {
                completion(false)
                return
            }
            guard waiting.count < Self.maxWaiting else {
                // очередь забита: честно отказываем, отправитель
                // повторит по своему бэкоффу
                droppedByBacklog += 1
                stateLine = "очередь передачи забита (\(waiting.count)) — "
                          + "жду окно эфира, отброшено \(droppedByBacklog)"
                completion(false)
                return
            }
            waiting.append((Self.priority(of: packet), packet, completion))
            waiting.sort { $0.priority < $1.priority }
            drainQueue()
        }
    }

    private func drainQueue() {
        guard toRadio != nil, node?.state == .connected else {
            queuedForAirtime = waiting.count
            return
        }
        while let next = waiting.first {
            let now = Date()
            guard gate.canWrite(now: now) else {
                // узел ещё отдаёт свою очередь — дочитать, потом писать
                queuedForAirtime = waiting.count
                scheduleDrain(after: 1)
                return
            }
            guard airtime.canSend(bytes: next.packet.count) else {
                // дьюти-цикл: честно ждём, статус наружу
                stateLine = "канал занят — жду окно эфира"
                queuedForAirtime = waiting.count
                scheduleDrain(after: 10)
                return
            }
            let pause = pacer.delayUntilFree(now: now)
            guard pause == 0 else {
                // темп записи: следующей записи ещё рано
                queuedForAirtime = waiting.count
                scheduleDrain(after: pause)
                return
            }
            waiting.removeFirst()
            transmit(next.packet, completion: next.completion)
        }
        queuedForAirtime = 0
    }

    private func transmit(_ packet: [UInt8],
                          completion: @escaping @Sendable (Bool) -> Void) {
        guard let node, let toRadio else { completion(false); return }
        sendTag &+= 1
        // блоб больше лимита — фрагментируем САМИ (номер+всего в
        // заголовке), рамка та же, что у BLE-линка
        let pieces = packet.count <= config.payloadLimit
            ? [[sendTag, 0, 1] + packet]
            : BleLink.fragment(packet, mtu: config.payloadLimit + 3,
                               tag: sendTag)
        for piece in pieces {
            packetCounter &+= 1
            let frame = MiniProto.toRadio(payload: piece,
                                          packetID: packetCounter)
            node.writeValue(Data(frame), for: toRadio, type: .withResponse)
            airtime.record(bytes: piece.count)
            pacer.noteWrite(now: Date())   // темп следующей записи
            TransportDiary.note("toRadio: пакет \(piece.count) Б")
        }
        // запись ушла в стек при живом соединении; доставку до адресата
        // подтверждает envelope-ack уровнем выше (как у BLE-линка)
        completion(node.state == .connected)
    }

    private func readAllFromRadio() {
        guard let node, let fromRadio else { return }
        gate.noteReadRequested(now: Date())   // дренаж: записи ждут
        node.readValue(for: fromRadio)   // ответ придёт в didUpdateValue
    }
}

// MARK: - Ядро-автомат: события BLE как значения (шов 03.08)
//
// Вся логика решений бывших делегатов живёт здесь и зовёт ТОЛЬКО
// протоколы NodeCentralLink/NodePeripheralLink — конкретные классы
// CoreBluetooth ей не видны. Настоящие колбэки транслирует тонкий
// адаптер ниже (образец шва — NodeProbe.ingest); тесты кормят эти
// методы событиями напрямую и читают журнал команд двойника.
// Вызывать строго на self.queue.

nonisolated extension MeshtasticLink {
    /// Система вернула нам состояние после выгрузки в фоне:
    /// подхватываем узел, который уже был подключён, и не сканируем.
    func willRestore(peripherals restored: [NodePeripheralLink]) {
        guard let mine = restored.first(where: { p in
            config.peripheralName.isEmpty
                || (p.name ?? "").lowercased()
                    .contains(config.peripheralName.lowercased())
        }) else { return }
        node = mine
        claimDelegate(mine)
        attachedNodeName = mine.name
        stateLine = "восстановлен из фона: \(mine.name ?? "устройство")"
        TransportDiary.note("willRestoreState: \(mine.name ?? "?"), "
                            + "state \(mine.state.rawValue)")
        // характеристики после реставрации нужно найти заново
        if mine.state == .connected {
            mine.discoverServices([Self.serviceUUID])
        } else {
            central?.connect(mine)
        }
    }

    func didUpdateState(poweredOn: Bool) {
        guard poweredOn else {
            // Bluetooth выключили — ОТПУСТИТЬ узел. Иначе поиск после
            // включения молча игнорирует находки (guard node == nil), и
            // связь не восстанавливается до перезапуска приложения.
            // Поймано владельцем 02.08: «отключал блютус и теперь
            // телефон не может найти устройство».
            dropNode(reason: "Bluetooth выключен")
            return
        }
        // на всякий случай: держим ссылку только на живое соединение
        if let node, node.state != .connected {
            dropNode(reason: "устройство пропало, ищу снова")
        }
        // Реставрация (дневник 03.08): willRestoreState приходит ДО
        // poweredOn, и discoverServices, выданный там, молча теряется —
        // узел «подключён», а характеристик нет, приложение бессмысленно
        // сканирует уже подключённое. Переиздать обнаружение теперь,
        // когда стек готов.
        if let node, node.state == .connected, fromRadio == nil {
            TransportDiary.note("poweredOn: переиздаю discoverServices "
                                + "для восстановленного узла")
            node.discoverServices([Self.serviceUUID])
            return
        }
        // КЛЮЧЕВОЕ (02.08, живой радиотест): периферия, уже подключённая
        // на уровне СИСТЕМЫ (bond + автоподключение iOS), НЕ появляется в
        // результатах скана — сканом её не найти никогда. Сначала
        // спрашиваем систему, что уже подключено, и берём своё.
        if node == nil {
            let connected = central?.retrieveConnectedNodes(
                withServices: [Self.serviceUUID]) ?? []
            let mine = connected.first { p in
                config.peripheralName.isEmpty
                    || (p.name ?? "").lowercased()
                        .contains(config.peripheralName.lowercased())
            }
            if let mine {
                node = mine
                claimDelegate(mine)
                stateLine = "беру уже подключённое: \(mine.name ?? "устройство")"
                TransportDiary.note("беру системно подключённый: "
                                    + (mine.name ?? "?"))
                central?.connect(mine)         // подтвердить владение
                return
            }
        }
        TransportDiary.note("сканирую эфир BLE (bluetooth включён)")
        central?.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    /// Отпустить периферию и обнулить характеристики.
    private func dropNode(reason: String) {
        setLinkUp(false)
        node = nil
        toRadio = nil
        fromRadio = nil
        fromNum = nil
        attachedNodeName = nil
        stateLine = reason
        TransportDiary.note("узел отпущен: \(reason)")
        // узла нет — вердикты о его отдаче больше не актуальны
        detector = StuckLinkDetector()
        if lastWarning != nil {
            lastWarning = nil
            onLinkWarning?(nil)
        }
    }

    func didDiscoverPeripheral(_ peripheral: NodePeripheralLink) {
        // мок ↔ живой узел выбираются настройкой peripheralName
        // Имя радио — ПОДСТРОКА без учёта регистра: достаточно ввести
        // «9e8f», не помня полное «Meshtastic_9e8f» (02.08: телефон
        // цеплял чужой узел, потому что фильтр пустой, а точное имя
        // владелец не знал).
        if !config.peripheralName.isEmpty,
           !(peripheral.name ?? "").lowercased()
                .contains(config.peripheralName.lowercased()) { return }
        guard node == nil else { return }
        node = peripheral
        claimDelegate(peripheral)
        central?.stopScan()
        central?.connect(peripheral)
        stateLine = "подключаюсь: \(peripheral.name ?? "устройство")…"
    }

    func didConnect(_ peripheral: NodePeripheralLink) {
        TransportDiary.note("подключён: \(peripheral.name ?? "?")")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func didDisconnect() {
        dropNode(reason: "радио потеряно — ищу снова")
        central?.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    /// Ошибка записи в узел (радиотест 02.08): без этого обработчика
    /// отказ характеристики терялся молча — приложение считало
    /// отправку успешной по факту «соединение живо», а байты до узла
    /// не доезжали. Теперь причина видна в состоянии транспорта.
    func didWriteError(_ error: Error?) {
        guard let error else {
            writeFailures = 0
            return
        }
        writeFailures += 1
        stateLine = "устройство не приняло пакет: \(error.localizedDescription)"
        TransportDiary.note("ОШИБКА записи: \(error.localizedDescription)")
    }

    func didDiscoverServices(_ services: [CBService],
                             on peripheral: NodePeripheralLink) {
        for s in services where s.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics(
                [Self.toRadioUUID, Self.fromRadioUUID, Self.fromNumUUID],
                for: s)
        }
    }

    func didDiscoverCharacteristics(of service: CBService,
                                    on peripheral: NodePeripheralLink) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.toRadioUUID: toRadio = c
            case Self.fromRadioUUID: fromRadio = c
            case Self.fromNumUUID:
                fromNum = c
                peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        if toRadio != nil, fromRadio != nil {
            setLinkUp(true)
            attachedNodeName = node?.name
            stateLine = "радиоканал готов: \(node?.name ?? "устройство")"
            // конфиг-дамп пойдёт заново — факты собираются с нуля
            // (полевой регресс 13.08: профиль «Имя —» при живом канале)
            factsParser = NodeFactsParser()
            liveFacts = NodeProbe.NodeFacts()
            TransportDiary.note("характеристики готовы (\(node?.name ?? "?")), шлю want_config")
            // рукопожатие client-api: want_config_id (ToRadio, поле 3) —
            // узел начинает отдавать состояние только после него
            if let toRadio, let node {
                let hello = MiniProto.key(3, wire: 0)
                    + MiniProto.varint(UInt64.random(in: 1..<0xFFFF))
                node.writeValue(Data(hello), for: toRadio,
                                type: .withResponse)
            }
            // Порядок — часть замка на клин (03.08): сначала ДОЧИТАТЬ
            // конфиг-дамп и накопленную очередь узла, и только по
            // пустому чтению drainQueue() откроет запись. Раньше здесь
            // был drainQueue() до чтения — весь outbox вываливался
            // залпом поверх дренажа и клинил PhoneAPI узла.
            readAllFromRadio()
            schedulePulse()
        }
    }

    /// Кадр FromRadio — в сборщик фактов; по config_complete факты
    /// уходят в реестр (кэш переживает переподключения и перезапуск).
    /// internal — замок кормит синтетическими кадрами (NodeProbeTests).
    func harvestFacts(_ bytes: [UInt8]) {
        let complete = factsParser.ingest(bytes)
        liveFacts = factsParser.facts
        if complete, let id = node?.identifier {
            NodeRegistry.record(id: id, name: liveFacts.longName,
                                region: liveFacts.region,
                                nodeCount: liveFacts.nodeCount)
            TransportDiary.note("факты узла собраны линком: "
                + "\(liveFacts.longName ?? "?") · "
                + "\(liveFacts.region ?? "?") · "
                + "узлов \(liveFacts.nodeCount)")
        }
    }

    func didUpdateValue(uuid: CBUUID, data value: Data?,
                        on peripheral: NodePeripheralLink) {
        if uuid == Self.fromNumUUID {
            // значение — счётчик пакетов узла (uint32 LE): им кормится
            // детектор клина; notify и пульс-чтение приходят одинаково
            if let data = value, data.count >= 4 {
                let value = UInt32(data[0]) | UInt32(data[1]) << 8
                    | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
                detector.noteFromNum(value, now: Date())
                evaluateLink()
                // в дневник — только СМЕНА счётчика (реальный пакет),
                // не каждый пульс-опрос
                if diaryDedup.fromNumChanged(value) {
                    TransportDiary.note("fromNum: \(value)")
                }
            }
            if fromRadio == nil {
                // Реставрация iOS вернула живую подписку БЕЗ открытых
                // характеристик (дневник 03.08: fromNum тикал, а читать
                // было нечем, приложение бесцельно сканировало уже
                // подключённый узел). Усыновить периферию и дообнаружить
                // сервисы — чтение возобновится из didDiscover.
                TransportDiary.note("fromNum без fromRadio — "
                                    + "дообнаруживаю сервисы")
                node = peripheral
                claimDelegate(peripheral)
                peripheral.discoverServices([Self.serviceUUID])
                return
            }
            readAllFromRadio()      // новый пакет в очереди узла
            return
        }
        guard uuid == Self.fromRadioUUID else { return }
        guard let data = value, !data.isEmpty else {
            // очередь узла дочитана — окно записи; в дневник — только
            // ПЕРЕХОД данные→пусто, не каждое пустое пульс-чтение
            if diaryDedup.emptyReadTransition() {
                TransportDiary.note("fromRadio: пусто — дочитано, окно записи")
            }
            gate.noteEmptyRead()
            drainQueue()
            return
        }
        diaryDedup.noteDataRead()
        gate.noteData(now: Date())
        detector.noteData(now: Date())
        evaluateLink()
        TransportDiary.note("fromRadio: \(data.count) Б — "
                            + Self.describeFromRadio(Array(data)))
        // конфиг-дамп → живые факты узла (профиль в .yielded, 13.08)
        harvestFacts(Array(data))
        if let (portnum, payload) = MiniProto.fromRadioPayload(Array(data)),
           portnum == 256,
           let whole = BleLink.assemble(into: &assembly,
                                        fragment: payload) {
            onReceive?(whole)
        }
        readAllFromRadio()          // «читать до пустого буфера»
    }

    /// Классификация кадра FromRadio для дневника: какое верхнее поле
    /// пришло (mesh.proto: 2=packet, 3=my_info, 4=node_info, 5=config,
    /// 7=config_complete_id, 13=metadata).
    nonisolated static func describeFromRadio(_ bytes: [UInt8]) -> String {
        let fields = MiniProto.fields(bytes)
        if fields[7] != nil { return "config_complete — хендшейк завершён" }
        if let mesh = fields[2]?.first {
            let portnum = MiniProto.fields(mesh)[4]?.first
                .flatMap { MiniProto.fields($0)[1]?.first }
                .flatMap { MiniProto.readVarint($0) }
            return "packet, portnum \(portnum.map(String.init) ?? "?")"
        }
        let known = [3: "my_info", 4: "node_info", 5: "config",
                     13: "metadata"]
        for (id, name) in known where fields[id] != nil { return name }
        return "поля \(fields.keys.sorted())"
    }
}

// MARK: - Тонкий адаптер: живые колбэки CoreBluetooth → события ядра
//
// Здесь НЕТ логики — только трансляция настоящих делегатных вызовов в
// методы-события выше (значениями). Колбэки приходят на self.queue,
// потому что центральный менеджер создан с ней.

nonisolated extension MeshtasticLink: CBCentralManagerDelegate,
                                      CBPeripheralDelegate {

    /// Назначить себя делегатом настоящей периферии — деталь живого
    /// стека; двойник в тестах делегата не имеет, события подаёт тест.
    func claimDelegate(_ peripheral: NodePeripheralLink) {
        (peripheral as? CBPeripheral)?.delegate = self
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey]
            as? [CBPeripheral] ?? []
        willRestore(peripherals: restored)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        didUpdateState(poweredOn: central.state == .poweredOn)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        didDiscoverPeripheral(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        didConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        didDisconnect()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        didWriteError(error)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral.services ?? [], on: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        didDiscoverCharacteristics(of: service, on: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        didUpdateValue(uuid: characteristic.uuid,
                       data: characteristic.value, on: peripheral)
    }
}

/// Дедуп радио-строк дневника (13.08): пульс каждые 2 с флудил
/// fromNum/«пусто — дочитано», 64-КБ хвост дневника съедал историю
/// за ~2 часа — полевое окно и пульсы уведомлений вырезались.
/// Правила: fromNum — только при СМЕНЕ счётчика; «пусто — дочитано» —
/// только на переходе данные→пусто. Детектор клина кормится всеми
/// чтениями как раньше — дедуп только про строки дневника.
nonisolated struct RadioDiaryDedup {
    private var lastFromNum: UInt32?
    private var lastReadHadData = false

    /// true — счётчик изменился, строку писать.
    mutating func fromNumChanged(_ value: UInt32) -> Bool {
        defer { lastFromNum = value }
        return value != lastFromNum
    }

    /// Пришло непустое чтение fromRadio.
    mutating func noteDataRead() { lastReadHadData = true }

    /// true — переход данные→пусто, строку писать; повторное пустое —
    /// молчание.
    mutating func emptyReadTransition() -> Bool {
        defer { lastReadHadData = false }
        return lastReadHadData
    }
}
