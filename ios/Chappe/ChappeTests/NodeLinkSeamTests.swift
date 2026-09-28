import Foundation
import CoreBluetooth
import Testing
@testable import Chappe

// ============================================================================
// Шов тестируемости транспорта (решение владельца 03.08).
//
// Эти тесты кормят ядро-автомат MeshtasticLink событиями-значениями
// (willRestore / didUpdateState / didConnect / didDiscover… /
// didUpdateValue) и проверяют ЖУРНАЛ КОМАНД двойника узла — ровно тот
// слой «проводки», где жили оба бага реставрации и клин отдачи узла
// 03.08 (docs/reports/reception_diagnosis_2026-08-03.md), невидимые
// прежней сюите (docs/reports/transport_tests_audit_2026-08-03.md).
//
// Правило ревизии: ожидания в тестах — ЛИТЕРАЛЫ полевых требований
// (зазор 1.0 с, окно тишины 3.0 с), не символьные ссылки на константы
// проверяемого кода.
// ============================================================================

// MARK: - Двойники

/// Двойник центрального менеджера: пишет команды транспорта в журнал.
nonisolated final class FakeCentral: NodeCentralLink {
    var state: CBManagerState = .unknown
    /// Что «система» считает уже подключённым (retrieveConnectedNodes).
    var connected: [NodePeripheralLink] = []
    private(set) var journal: [String] = []

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?) {
        journal.append("scan")
    }
    func stopScan() { journal.append("stopScan") }
    func connect(_ peripheral: NodePeripheralLink) {
        journal.append("connect")
    }
    func cancelPeripheralConnection(_ peripheral: NodePeripheralLink) {
        journal.append("cancel")
    }
    func retrieveConnectedNodes(withServices serviceUUIDs: [CBUUID])
        -> [NodePeripheralLink] { connected }
}

/// Двойник узла: журнал команд с метками времени + модель поведения
/// настоящего стека и настоящей прошивки:
///   - команды до poweredOn теряются молча (как в живом CoreBluetooth
///     при willRestoreState до готовности стека);
///   - модель клина PhoneAPI (полевой диагноз 03.08): запись ToRadio
///     во время собственного дренажа — узел навсегда перестаёт
///     отдавать очередь (глухота до разрыва BLE).
nonisolated final class FakeNode: NodePeripheralLink {
    struct Entry {
        let at: Date
        let command: String
    }

    private(set) var journal: [Entry] = []
    weak var link: MeshtasticLink?

    var identifier = UUID()
    var name: String?
    var state: CBPeripheralState = .connected
    /// false — стек ещё не poweredOn: команды записываются в журнал,
    /// но узел их «не видит» (потерялись).
    var stackReady = false
    /// Накопленная очередь узла: FromRadio-кадры, отдаются по чтению.
    var nodeQueue: [Data] = []
    /// Счётчик FromNum (uint32 LE в живом узле).
    var fromNumCounter: UInt32 = 1
    /// Клин случился: узел больше не отвечает на чтения FromRadio.
    private(set) var wedged = false

    let service: CBMutableService

    init() {
        service = CBMutableService(type: MeshtasticLink.serviceUUID,
                                   primary: true)
        service.characteristics = [
            CBMutableCharacteristic(
                type: MeshtasticLink.toRadioUUID, properties: [.write],
                value: nil, permissions: [.writeable]),
            CBMutableCharacteristic(
                type: MeshtasticLink.fromRadioUUID, properties: [.read],
                value: nil, permissions: [.readable]),
            CBMutableCharacteristic(
                type: MeshtasticLink.fromNumUUID,
                properties: [.notify, .read],
                value: nil, permissions: [.readable]),
        ]
    }

    private func log(_ command: String) {
        journal.append(Entry(at: Date(), command: command))
    }

    private func shortName(_ uuid: CBUUID) -> String {
        switch uuid {
        case MeshtasticLink.toRadioUUID: return "toRadio"
        case MeshtasticLink.fromRadioUUID: return "fromRadio"
        case MeshtasticLink.fromNumUUID: return "fromNum"
        default: return uuid.uuidString
        }
    }

    // MARK: команды транспорта

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        log("discoverServices")
        guard stackReady else { return }    // команда потеряна до poweredOn
        link?.didDiscoverServices([service], on: self)
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?,
                                 for service: CBService) {
        log("discoverCharacteristics")
        guard stackReady else { return }
        link?.didDiscoverCharacteristics(of: service, on: self)
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        log("setNotify \(shortName(characteristic.uuid))")
    }

    func readValue(for characteristic: CBCharacteristic) {
        log("read \(shortName(characteristic.uuid))")
        guard stackReady, let link else { return }
        if characteristic.uuid == MeshtasticLink.fromNumUUID {
            let v = fromNumCounter
            link.didUpdateValue(
                uuid: MeshtasticLink.fromNumUUID,
                data: Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                            UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]),
                on: self)
            return
        }
        guard characteristic.uuid == MeshtasticLink.fromRadioUUID else {
            return
        }
        if wedged { return }    // глухота: ответ не приходит ВОВСЕ
        if nodeQueue.isEmpty {
            log("отдал: пусто")
            link.didUpdateValue(uuid: MeshtasticLink.fromRadioUUID,
                                data: Data(), on: self)
        } else {
            let frame = nodeQueue.removeFirst()
            log("отдал: кадр \(frame.count) Б")
            link.didUpdateValue(uuid: MeshtasticLink.fromRadioUUID,
                                data: frame, on: self)
        }
    }

    func writeValue(_ data: Data, for characteristic: CBCharacteristic,
                    type: CBCharacteristicWriteType) {
        guard characteristic.uuid == MeshtasticLink.toRadioUUID else {
            log("write \(shortName(characteristic.uuid))")
            return
        }
        // want_config — ToRadio поле 3, varint: ключ 0x18; кадры
        // очереди (MeshPacket, поле 1, len) начинаются с 0x0A
        if data.first == 0x18 {
            log("write want_config")
            return
        }
        log("write packet")
        if !nodeQueue.isEmpty {
            // запись поверх собственного дренажа — клин PhoneAPI
            // (воспроизведён трижды 03.08); дальше узел «глохнет»
            wedged = true
        }
    }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        512
    }
}

/// Потокобезопасная копилка принятых блобов (onReceive зовётся
/// на очереди линка). Имя не ReceivedBox — такой уже есть в
/// TransportTests.swift.
private nonisolated final class SeamReceivedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UInt8]] = []
    func add(_ value: [UInt8]) {
        lock.lock(); items.append(value); lock.unlock()
    }
    var all: [[UInt8]] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

// MARK: - Тесты

nonisolated struct NodeLinkSeamTests {

    /// Стенд: линк с двойниками вместо живого CoreBluetooth.
    private func makeRig() -> (MeshtasticLink, FakeCentral, FakeNode) {
        let link = MeshtasticLink()
        let central = FakeCentral()
        let node = FakeNode()
        node.link = link
        // имя двойника обязано пройти фильтр peripheralName из конфига
        // тест-хоста (какой бы он ни был)
        node.name = link.config.peripheralName.isEmpty
            ? "Meshtastic_test" : "x\(link.config.peripheralName)x"
        link.makeCentral = { _, _ in central }
        link.start()
        link.queue.sync {}   // фабрика отработала, central установлен
        return (link, central, node)
    }

    /// Конфиг-кадр FromRadio: my_info (поле 3) — данные без packet.
    private func configFrame() -> Data {
        Data(MiniProto.lenField(
            3, MiniProto.key(1, wire: 0) + MiniProto.varint(7)))
    }

    /// FromRadio{ packet=2 { decoded=4 { portnum=1: 256,
    /// payload=2: [tag,0,1]+blob } } } — наш блоб в одном фрагменте.
    private func packetFrame(blob: [UInt8], tag: UInt8 = 9) -> Data {
        let piece: [UInt8] = [tag, 0, 1] + blob
        let dataMsg = MiniProto.key(1, wire: 0) + MiniProto.varint(256)
            + MiniProto.lenField(2, piece)
        return Data(MiniProto.lenField(2, MiniProto.lenField(4, dataMsg)))
    }

    private func fromNumData(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    // MARK: (а) реставрация

    @Test("реставрация: discoverServices до poweredOn теряется — после poweredOn обязан быть переиздан, fromRadio открывается")
    func restorationReissuesDiscoverAfterPoweredOn() {
        let (link, central, node) = makeRig()
        // willRestoreState приходит ДО poweredOn — стек, как настоящий,
        // молча теряет команду discoverServices
        link.queue.sync { link.willRestore(peripherals: [node]) }
        #expect(link.queue.sync {
            node.journal.filter { $0.command == "discoverServices" }.count
        } == 1, "команда выдана из willRestore (и потеряна стеком)")

        node.stackReady = true
        central.state = .poweredOn
        link.queue.sync { link.didUpdateState(poweredOn: true) }

        let journal = link.queue.sync { node.journal.map(\.command) }
        #expect(journal.filter { $0 == "discoverServices" }.count == 2,
                "после poweredOn обнаружение сервисов обязано быть переиздано — иначе узел «подключён», а характеристик нет")
        #expect(journal.contains("read fromRadio"),
                "fromRadio открыт — чтение очереди узла началось")
    }

    // MARK: (б) страховка

    @Test("страховка: notify fromNum при неоткрытой fromRadio — дообнаружение сервисов и возобновление чтений")
    func fromNumWithoutFromRadioRediscovers() {
        let (link, _, node) = makeRig()
        node.stackReady = true
        node.nodeQueue = [configFrame()]
        // реставрация вернула живую подписку БЕЗ открытых характеристик:
        // notify тикает, а node/fromRadio у линка нет
        link.queue.sync {
            link.didUpdateValue(uuid: MeshtasticLink.fromNumUUID,
                                data: fromNumData(5), on: node)
        }
        let journal = link.queue.sync { node.journal.map(\.command) }
        #expect(journal.contains("discoverServices"),
                "периферия усыновлена, сервисы дообнаруживаются")
        #expect(journal.contains("read fromRadio"),
                "чтения возобновились")
        #expect(link.queue.sync { node.nodeQueue.isEmpty },
                "накопленная очередь узла дочитана до пустого")
    }

    // MARK: (в) дисциплина записи

    // Блок 3 (стендовый прогон 10.08, живой узел 9e8f): ВЫКЛ/ВКЛ
    // Bluetooth — линк обязан честно умереть (не «подключён» на
    // мёртвом, полевая ложь 09.08) и восстановиться сам, без
    // перезагрузки узла. Живой цикл подтверждён консолью:
    // «узел отпущен: Bluetooth выключен» → «сканирую эфир BLE» →
    // «характеристики готовы (Meshtastic_9e8f)».
    @Test("toggle Bluetooth: линк честно падает и восстанавливается сам")
    func bluetoothToggleReconnects() async throws {
        let (link, central, node) = makeRig()
        node.stackReady = true
        central.state = .poweredOn
        central.connected = [node]
        link.queue.sync { link.didUpdateState(poweredOn: true) }
        link.queue.sync { link.didConnect(node) }
        #expect(link.isLinkUp, "мок довёл линк до готовности")

        // ВЫКЛ: живость обязана упасть сразу — по ней маршрутизация
        // (блок 1) перестаёт лить в мёртвый линк
        link.queue.sync { link.didUpdateState(poweredOn: false) }
        #expect(!link.isLinkUp, Comment(rawValue:
                "мёртвый линк не смеет считаться живым: апп врал "
                + "«подключён» и слал в пустоту (поле 09.08)"))

        // ВКЛ: линк сам берёт системно подключённый узел (bond iOS)
        // и доводит канал до готовности
        link.queue.sync { link.didUpdateState(poweredOn: true) }
        let reachedOut = link.queue.sync {
            central.journal.contains("connect")
                || central.journal.contains("scan")
        }
        #expect(reachedOut, "после включения линк обязан искать узел")
        link.queue.sync { link.didConnect(node) }
        #expect(link.isLinkUp, Comment(rawValue:
                "восстановление без перезагрузки узла — полевой случай "
                + "09.08 требовал передёргивать узел руками"))
    }

    @Test("дисциплина: при полном outbox ни одной записи пакета до пустого чтения; темп записей ≥ 1.0 с")
    func noPacketWritesBeforeEmptyReadAndPaced() async throws {
        let (link, central, node) = makeRig()
        node.stackReady = true
        central.state = .poweredOn
        central.connected = [node]
        // накопленная очередь узла: хендшейк-дамп + пакет
        node.nodeQueue = [configFrame(), configFrame(), configFrame(),
                          packetFrame(blob: [0x21, 1, 2, 3])]
        link.queue.sync { link.didUpdateState(poweredOn: true) }
        link.queue.sync { link.didConnect(node) }
        // полный outbox сразу после поднятия линка, ДО конца дренажа
        // очереди узла (блок 1, 10.08: send до готовности линка теперь
        // честно отказывает — насос не зовёт мёртвое радио; суть замка
        // 03.08 неизменна: ни одной записи пакета до пустого чтения)
        #expect(link.isLinkUp, "мок довёл линк до готовности")
        for i in 0..<3 {
            link.send([0x22, UInt8(i)], toHost: "mesh") { _ in }
        }
        link.queue.sync {}   // send-ы легли в очередь передачи

        // первая запись уходит в каскаде после пустого чтения, остальные
        // приходят по расписанию пейсера — ждём все три
        var tries = 0
        while link.queue.sync(execute: {
            node.journal.filter { $0.command == "write packet" }.count
        }) < 3, tries < 100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            tries += 1
        }

        let journal = link.queue.sync { node.journal }
        let commands = journal.map(\.command)
        #expect(commands.filter { $0 == "write packet" }.count == 3,
                "весь outbox в итоге ушёл")

        let emptyIndex = commands.firstIndex(of: "отдал: пусто")
        let firstPacket = commands.firstIndex(of: "write packet")
        #expect(emptyIndex != nil, "очередь узла дочитана до пустого")
        #expect(firstPacket != nil)
        if let e = emptyIndex, let p = firstPacket {
            #expect(e < p, "НИ ОДНОЙ записи пакета до пустого чтения — порядок «дочитал → писал», замок на клин 03.08")
            // до пустого чтения в ToRadio уходит ровно одна запись —
            // want_config рукопожатия client-api, без неё узел молчит
            let writesBefore = commands.prefix(upTo: e)
                .filter { $0.hasPrefix("write") }
            #expect(Array(writesBefore) == ["write want_config"],
                    "до конца дренажа — только want_config, никаких пакетов")
        }

        // темп: зазор между записями ≥ 1.0 с — ЛИТЕРАЛ полевого
        // требования (LoRa SF11 ≈ 1 с/пакет), не ссылка на константу
        // кода; 0.05 — допуск на зернистость таймера
        let stamps = journal.filter { $0.command == "write packet" }
            .map(\.at)
        for (a, b) in zip(stamps, stamps.dropFirst()) {
            #expect(b.timeIntervalSince(a) >= 1.0 - 0.05,
                    "записи идут с темпом ≥ 1.0 с, не залпом")
        }
        #expect(link.queue.sync { node.wedged } == false,
                "узел-двойник не получил запись во время дренажа")
    }

    // MARK: (г) регрессионный замок клина

    @Test("замок клина: узел, глохнущий от записи во время дренажа, с нашей дисциплиной не глохнет — приём жив после залпа")
    func wedgingNodeModelNeverWedgesUnderDiscipline() async throws {
        let (link, central, node) = makeRig()
        node.stackReady = true
        central.state = .poweredOn
        central.connected = [node]
        // накопленная за ночь очередь узла — отдаётся залпом
        node.nodeQueue = (0..<5).map { _ in configFrame() }
        let received = SeamReceivedBox()
        link.onReceive = { received.add($0) }
        for i in 0..<2 {
            link.send([0x22, UInt8(i)], toHost: "mesh") { _ in }
        }
        link.queue.sync {}
        link.queue.sync { link.didUpdateState(poweredOn: true) }
        link.queue.sync { link.didConnect(node) }

        var tries = 0
        while link.queue.sync(execute: {
            node.journal.filter { $0.command == "write packet" }.count
        }) < 2, tries < 100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            tries += 1
        }
        #expect(link.queue.sync { node.wedged } == false,
                "дисциплина не дала узлу получить запись во время дренажа")

        // живой приём ПОСЛЕ залпа (раньше тут наступала глухота):
        // узел получил новый пакет и уведомил счётчиком
        link.queue.sync {
            node.nodeQueue = [packetFrame(blob: [0x33, 7, 7])]
            node.fromNumCounter += 1
            link.didUpdateValue(uuid: MeshtasticLink.fromNumUUID,
                                data: fromNumData(node.fromNumCounter),
                                on: node)
        }
        #expect(received.all.contains([0x33, 7, 7]),
                "глухоты нет: пакет после залпа доставлен приложению")
        #expect(link.queue.sync { node.wedged } == false)
    }

    // MARK: калибровка литералами (правило ревизии 03.08)

    @Test("калибровка: зазор записей WritePacer — ровно 1.0 с (литерал, LoRa SF11 ≈ 1 с/пакет)")
    func pacerGapIsOneSecondLiteral() {
        var pacer = WritePacer()
        let t0 = Date()
        pacer.noteWrite(now: t0)
        #expect(abs(pacer.delayUntilFree(now: t0) - 1.0) < 0.001,
                "смена константы в коде обязана уронить этот тест")
    }

    @Test("калибровка: ack сдаются после 3.0 с тишины приёма (литерал)")
    func ackQuietWindowIsThreeSecondsLiteral() {
        var acks = AckAggregator()
        let t0 = Date()
        acks.add(7, now: t0)
        #expect(acks.takeDue(now: t0.addingTimeInterval(2.9)).isEmpty,
                "до 3.0 с тишины ack не уходят")
        #expect(acks.takeDue(now: t0.addingTimeInterval(3.0 + 0.01)) == [7],
                "после 3.0 с тишины — уходят")
    }
}
