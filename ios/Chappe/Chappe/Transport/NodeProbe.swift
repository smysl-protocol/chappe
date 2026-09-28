import Foundation
import Combine
import CoreBluetooth

// ============================================================================
// NodeProbe — диагностическое соединение с радиоузлом (бриф 02.08).
//
// Отдельный от транспорта CBCentral: экран «Радиоузел» в Настройках
// живёт своей жизнью и не мешает MeshtasticLink (который включается
// transportKind=mesh; одновременная работа двух центральных менеджеров
// с одной периферией не предполагается — экран диагностический).
//
// Поток: скан ТОЛЬКО по сервису узла → тап по строке → connect (таймаут
// 10 с, до 2 ретраев) → discoverServices → discoverCharacteristics →
// подписка FromNum (первое защищённое действие: система при
// необходимости показывает диалог кода — у нас видимое состояние
// «ожидание кода», не зависание) → want_config_id → чтение FromRadio
// до пустого буфера → факты: имя узла, прошивка, регион, размер NodeDB.
//
// Номера полей — официальный mesh.proto/config.proto (сверено 02.08):
// FromRadio: my_info=3, node_info=4, config=5, config_complete_id=7,
// metadata=13; MyNodeInfo.my_node_num=1; NodeInfo.num=1, .user=2;
// User.long_name=2; DeviceMetadata.firmware_version=1;
// Config.lora=6; LoRaConfig.region=7 (enum RegionCode, SG_923=18).
//
// «MTU 512» из брифа — договорной параметр Android-стека; в
// CoreBluetooth MTU договаривает система, мы читаем фактический
// maximumWriteValueLength и показываем его в фактах.
// ============================================================================

@MainActor
final class NodeProbe: NSObject, ObservableObject {

    /// WP2 (02.08): соединение живёт на уровне приложения, не экрана.
    /// Раньше каждый вход в Настройки создавал новый NodeProbe и
    /// onDisappear рвал связь — «каждый раз заново сканирует и
    /// сопрягается». Экран теперь только отображает состояние shared.
    static let shared = NodeProbe()

    enum Phase: Equatable {
        case idle
        case bluetoothOff
        case scanning
        case connecting(name: String)
        case pairing            // «ожидание кода с экрана узла»
        case handshake          // конфиг-поток читается
        case ready              // факты собраны
        case reconnecting       // связь оборвалась — ждём узел обратно
        case yielded            // узел отдан транспорту — это НОРМА
        case failed(String)     // человеческая причина
    }

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    struct NodeFacts: Equatable {
        var longName: String?
        var firmware: String?
        var region: String?
        var nodeCount: Int = 0
        var writeLimit: Int?    // фактический лимит записи (аналог MTU)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var found: [Found] = []
    @Published private(set) var facts = NodeFacts()
    /// WP0: предупреждения о расхождении регионов (см. NodeRegistry).
    @Published private(set) var regionWarnings: [String] = []

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var target: CBPeripheral?
    private var toRadio: CBCharacteristic?
    private var fromRadio: CBCharacteristic?
    private var connectAttempts = 0
    private var timeoutTask: Task<Void, Never>?
    private var myNodeNum: UInt64?
    private var sawAnyData = false
    /// Сколько раз узел вернул пустой буфер ДО первых данных.
    private var emptyReads = 0
    /// Восстановление ждёт poweredOn (WP2).
    private var pendingRestore = false
    /// Момент последних данных от узла — для карточки статуса (WP3).
    private(set) var lastDataAt: Date?
    /// Сырые байты LoRaConfig из конфиг-потока — нужны смене региона:
    /// set_config заменяет секцию ЦЕЛИКОМ, поэтому отправлять надо
    /// узлов же конфиг с одной правкой, а не голый регион (иначе
    /// пресет/мощность/лимиты сбросятся в умолчания).
    private(set) var rawLoRa: [UInt8]?

    // enum RegionCode из config.proto (сверено 02.08)
    static let regionNames: [UInt64: String] = [
        0: "не задан", 1: "US", 2: "EU_433", 3: "EU_868", 4: "CN",
        5: "JP", 6: "ANZ", 7: "KR", 8: "TW", 9: "RU", 10: "IN",
        11: "NZ_865", 12: "TH", 13: "2.4 ГГц", 14: "UA_433",
        15: "UA_868", 16: "MY_433", 17: "MY_919", 18: "SG_923",
    ]

    // MARK: Управление

    /// Ключ сохранённого идентификатора периферии — реконнект без
    /// повторного полного сканирования (WP2).
    static let savedPeripheralKey = "node.lastPeripheral"

    func rememberPeripheral(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Self.savedPeripheralKey)
    }

    static var savedPeripheralID: UUID? {
        UserDefaults.standard.string(forKey: savedPeripheralKey)
            .flatMap(UUID.init(uuidString:))
    }

    /// Радио занято транспортом? Тогда диагностика к узлу НЕ лезет.
    ///
    /// Регрессия 02.08 (радиотест): WP2 сделал probe долгоживущим и
    /// восстанавливающим связь при старте — а MeshtasticLink находит
    /// узел ТОЛЬКО сканированием, и подключённый узел перестаёт
    /// рекламироваться. Два центральных менеджера на одной периферии
    /// = транспорт не видит узел и в эфир не уходит ничего.
    /// Владелец радио — транспорт; probe уступает.
    @MainActor
    static var radioOwnedByTransport: () -> Bool = {
        DeliveryManager.shared.transportKind == "mesh"
    }

    /// Отдать узел транспорту: разорвать своё соединение немедленно.
    /// Вызывается при включении транспорта «радио» (02.08: диагностика
    /// держала узел подключённым, тот не рекламировался, и транспорт
    /// не находил его сканом — сообщения не уходили).
    func yieldRadio() {
        timeoutTask?.cancel()
        if let target {
            self.target = nil
            central?.cancelPeripheralConnection(target)
        }
        central?.stopScan()
        found = []
        phase = .yielded
    }

    /// Вход на экран: НЕ трогать живое/восстанавливаемое соединение.
    /// Скан — только если соединения нет и оно не строится.
    func startIfNeeded() {
        #if DEBUG
        // dev: --radio-fake-yielded — рабочая фаза без Bluetooth
        // (симулятор): UI-замок достижимости контролов радиоэкрана
        // (полевое 13.08: кнопка региона не реагировала на тап)
        if ProcessInfo.processInfo.arguments
            .contains("--radio-fake-yielded") {
            phase = .yielded
            return
        }
        #endif
        if Self.radioOwnedByTransport() {
            phase = .yielded
            return
        }
        startIfNeededUnchecked()
    }

    private func startIfNeededUnchecked() {
        switch phase {
        case .ready, .connecting, .pairing, .handshake, .reconnecting:
            return
        case .idle, .bluetoothOff, .scanning, .failed, .yielded:
            if restoreConnection() { return }
            startScan()
        }
    }

    /// Восстановление по сохранённому идентификатору, без скана.
    /// true — восстановление запущено (или уже идёт), сканировать не надо.
    @discardableResult
    func restoreConnection() -> Bool {
        // радио принадлежит транспорту — молча не мешаем (см. выше)
        if Self.radioOwnedByTransport() { return false }
        guard let saved = Self.savedPeripheralID else { return false }
        if central == nil {
            // менеджер поднимется и продолжит в centralManagerDidUpdateState
            pendingRestore = true
            phase = .reconnecting
            central = CBCentralManager(delegate: self, queue: .main)
            return true
        }
        guard central?.state == .poweredOn else { return false }
        guard let peripheral = central?
            .retrievePeripherals(withIdentifiers: [saved]).first else {
            return false            // система узла не помнит — обычный скан
        }
        peripherals[peripheral.identifier] = peripheral
        target = peripheral
        peripheral.delegate = self
        phase = .reconnecting
        // connect без таймаута: система ждёт появления узла сколько
        // угодно — это и есть автопереподключение «узел ушёл из зоны»
        central?.connect(peripheral)
        return true
    }

    func startScan() {
        if Self.radioOwnedByTransport() {
            phase = .yielded
            return
        }
        // Уйти с висящего реконнекта чисто: target отцепляется ДО
        // cancel, чтобы его didDisconnect не перетёр фазу скана
        if let old = target {
            target = nil
            central?.cancelPeripheralConnection(old)
        }
        found = []
        facts = NodeFacts()
        phase = .scanning
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            scanIfPoweredOn()
        }
    }

    func stop() {
        timeoutTask?.cancel()
        if let target { central?.cancelPeripheralConnection(target) }
        central?.stopScan()
        target = nil
        toRadio = nil
        fromRadio = nil
        phase = .idle
    }

    /// Тап по строке устройства.
    func connect(_ item: Found) {
        guard let peripheral = peripherals[item.id] else { return }
        central?.stopScan()
        target = peripheral
        peripheral.delegate = self
        connectAttempts = 0
        attemptConnect(name: item.name)
    }

    private func attemptConnect(name: String) {
        guard let target else { return }
        connectAttempts += 1
        phase = .connecting(name: name)
        central?.connect(target)
        armTimeout(seconds: 10) { [weak self] in
            guard let self else { return }
            // таймаут с ретраем (п.6): две попытки, потом честный отказ
            if self.connectAttempts < 3 {
                self.central?.cancelPeripheralConnection(target)
                self.attemptConnect(name: name)
            } else {
                self.central?.cancelPeripheralConnection(target)
                self.phase = .failed("Устройство не отвечает — проверьте, что "
                                     + "оно включено и рядом, и попробуйте ещё раз")
            }
        }
    }

    private func armTimeout(seconds: Double,
                            _ body: @escaping @MainActor () -> Void) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            body()
        }
    }

    private func scanIfPoweredOn() {
        guard central?.state == .poweredOn else { return }
        // Уже подключённая системой периферия в скане не появляется —
        // спрашиваем систему напрямую (02.08, живой радиотест)
        if target == nil, let central,
           let connected = central.retrieveConnectedPeripherals(
               withServices: [MeshtasticLink.serviceUUID]).first {
            peripherals[connected.identifier] = connected
            if !found.contains(where: { $0.id == connected.identifier }) {
                found.append(Found(id: connected.identifier,
                                   name: connected.name ?? "устройство рядом",
                                   rssi: 0))
            }
        }
        central?.scanForPeripherals(
            withServices: [MeshtasticLink.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    // MARK: Смена региона (UX-проход 06.08, класс C — явное действие)

    /// Кадр ToRadio с админ-командой «сменить регион». LoRaConfig узла
    /// берётся КАК ЕСТЬ (сырые байты) и к нему дописывается region=code:
    /// при повторе скалярного поля в protobuf побеждает последнее,
    /// поэтому пресет/мощность/лимиты узла не затираются. Номера полей:
    /// AdminMessage.set_config=34 (admin.proto), Config.lora=6,
    /// LoRaConfig.region=7, portnum ADMIN_APP=6; адресат — сам узел
    /// (локальная админ-команда с телефона, ключ сессии не нужен).
    /// Чистая функция — покрыта замком RegionAdminTests на байтах,
    /// посчитанных вручную.
    nonisolated static func regionAdminFrame(rawLoRa: [UInt8], code: UInt64,
                                             nodeNum: UInt32,
                                             packetID: UInt32) -> [UInt8] {
        let lora = rawLoRa + MiniProto.key(7, wire: 0) + MiniProto.varint(code)
        let config = MiniProto.lenField(6, lora)
        let admin = MiniProto.lenField(34, config)
        return MiniProto.toRadio(payload: admin, packetID: packetID,
                                 portnum: 6, to: nodeNum)
    }

    /// Отправить узлу смену региона. true = команда записана в ToRadio.
    /// Запись — НЕ успех (правило 5): узел сохранит настройку и
    /// перезагрузится, связь оборвётся (didDisconnect уведёт в
    /// .reconnecting); подтверждение — регион, прочитанный заново
    /// после возвращения узла.
    func setRegion(code: UInt64) -> Bool {
        guard phase == .ready, let target, let toRadio,
              let nodeNum = myNodeNum, nodeNum <= UInt32.max,
              let rawLoRa else { return false }
        let frame = Self.regionAdminFrame(
            rawLoRa: rawLoRa, code: code, nodeNum: UInt32(nodeNum),
            packetID: UInt32.random(in: 1..<UInt32.max))
        target.writeValue(Data(frame), for: toRadio, type: .withResponse)
        return true
    }

    /// WP3: живой снимок для карточки статуса — только факты, кодом.
    func statusSnapshot() -> NetworkStatus.Snapshot {
        let connected = phase == .ready
        if connected || facts.longName != nil || facts.region != nil {
            return NetworkStatus.Snapshot(
                connectedNow: connected,
                nodeName: facts.longName,
                region: facts.region,
                knownNodeCount: facts.nodeCount > 0 ? facts.nodeCount : nil,
                lastContact: lastDataAt,
                regionWarnings: regionWarnings)
        }
        // Соединения в этой сессии не было — последнее известное из
        // реестра; connectedNow=false только если мы точно знаем, что
        // соединения нет (сервис жив, фаза не ready)
        var snapshot = NetworkStatus.defaultSnapshot()
        if phase != .idle { snapshot.connectedNow = false }
        return snapshot
    }
}

// MARK: - CoreBluetooth

extension NodeProbe: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if self.pendingRestore {
                    // WP2: сначала пробуем вернуть сохранённый узел без
                    // скана; не вышло — обычный поиск
                    self.pendingRestore = false
                    if self.restoreConnection() { return }
                    self.phase = .scanning
                }
                if self.phase == .bluetoothOff { self.phase = .scanning }
                self.scanIfPoweredOn()
            case .poweredOff:
                self.phase = .bluetoothOff
            case .unauthorized:
                self.phase = .failed("Нет разрешения на Bluetooth — "
                                     + "включите в Настройках телефона")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        // фильтр по сервису делает сам скан (withServices) — телевизоров
        // в списке больше нет; тут только дедуп и сортировка по сигналу
        let item = Found(id: peripheral.identifier,
                         name: peripheral.name ?? "устройство без имени",
                         rssi: RSSI.intValue)
        Task { @MainActor in
            self.peripherals[peripheral.identifier] = peripheral
            if let index = self.found.firstIndex(where: { $0.id == item.id }) {
                self.found[index] = item
            } else {
                self.found.append(item)
            }
            self.found.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.timeoutTask?.cancel()
            // Ре-рукопожатие читает NodeDB заново — счёт с нуля,
            // иначе узлы задваиваются (WP2: реконнект тем же объектом)
            self.facts = NodeFacts()
            self.myNodeNum = nil
            self.rawLoRa = nil
            self.emptyReads = 0
            self.sawAnyData = false
            self.facts.writeLimit = peripheral
                .maximumWriteValueLength(for: .withResponse)
            peripheral.discoverServices([MeshtasticLink.serviceUUID])
            // Подписка на защищённую характеристику дальше вызовет
            // системный диалог кода при RANDOM_PIN — покажем ожидание
            self.phase = .pairing
            self.armTimeout(seconds: 30) { [weak self] in
                self?.phase = .failed("Сопряжение не завершилось — если "
                    + "на устройстве показан код, введите его в системном диалоге; "
                    + "иначе попробуйте ещё раз")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.timeoutTask?.cancel()
            self.phase = .failed("Устройство не отвечает: "
                + (error?.localizedDescription ?? "соединение не удалось"))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            // Обрыв от уже брошенной периферии (stop/новый скан) — не наш
            guard peripheral.identifier == self.target?.identifier else {
                return
            }
            self.timeoutTask?.cancel()
            // WP2: рабочее соединение оборвалось (узел ушёл из зоны,
            // выключен, система разорвала) → автопереподключение.
            // connect без таймаута висит, пока узел не вернётся.
            if self.phase == .ready || self.phase == .reconnecting {
                self.phase = .reconnecting
                if let target = self.target {
                    self.central?.connect(target)
                }
                return
            }
            guard self.phase != .idle else { return }
            if self.sawAnyData {
                self.phase = .failed("Связь с устройством оборвалась — "
                                     + "попробуйте ещё раз")
            } else {
                // обрыв до первых данных — типичный отказ сопряжения
                self.phase = .failed("Сопряжение отклонено или код "
                                     + "неверен — попробуйте заново")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        for s in peripheral.services ?? []
        where s.uuid == MeshtasticLink.serviceUUID {
            peripheral.discoverCharacteristics(
                [MeshtasticLink.toRadioUUID, MeshtasticLink.fromRadioUUID,
                 MeshtasticLink.fromNumUUID], for: s)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for c in service.characteristics ?? [] {
                switch c.uuid {
                case MeshtasticLink.toRadioUUID: self.toRadio = c
                case MeshtasticLink.fromRadioUUID: self.fromRadio = c
                case MeshtasticLink.fromNumUUID:
                    peripheral.setNotifyValue(true, for: c)
                default: break
                }
            }
            guard let toRadio = self.toRadio, self.fromRadio != nil else {
                self.phase = .failed("У устройства нет нужного радиоканала — "
                                     + "похоже, это не наше устройство")
                return
            }
            // рукопожатие: want_config_id (ToRadio поле 3) → узел отдаёт
            // конфиг-поток; дальше читаем до пустого буфера
            self.phase = .handshake
            let hello = MiniProto.key(3, wire: 0)
                + MiniProto.varint(UInt64.random(in: 1..<0xFFFF))
            peripheral.writeValue(Data(hello), for: toRadio,
                                  type: .withResponse)
            self.readNext(peripheral)
            self.armTimeout(seconds: 20) { [weak self] in
                self?.phase = .failed("Устройство не отдало настройки — "
                                     + "попробуйте ещё раз")
            }
        }
    }

    @MainActor
    private func readNext(_ peripheral: CBPeripheral) {
        guard let fromRadio else { return }
        peripheral.readValue(for: fromRadio)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let bytes = characteristic.value.map(Array.init) ?? []
        let uuid = characteristic.uuid
        Task { @MainActor in
            if uuid == MeshtasticLink.fromNumUUID {
                self.readNext(peripheral)
                return
            }
            guard uuid == MeshtasticLink.fromRadioUUID else { return }
            if bytes.isEmpty {
                // Пустой буфер ДО первых данных — это не «поток дочитан»,
                // а «узел ещё не собрался» (после перезагрузки узла так
                // и бывает). Раньше здесь объявлялась готовность с
                // пустыми фактами — на экране прочерки (02.08, владелец).
                guard self.phase == .handshake else { return }
                if self.sawAnyData {
                    self.finishIfReady()
                    return
                }
                self.emptyReads += 1
                guard self.emptyReads <= 20 else {
                    self.phase = .failed("Устройство подключилось, но данных не "
                        + "отдаёт — попробуйте переподключить его питание")
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard self.phase == .handshake else { return }
                    self.readNext(peripheral)
                }
                return
            }
            self.sawAnyData = true
            self.lastDataAt = Date()
            self.ingest(bytes)
            self.readNext(peripheral)
        }
    }

    // MARK: Разбор фактов из FromRadio (номера полей — из шапки файла)

    /// internal — разбор фактов покрыт юнит-тестом на синтетических
    /// FromRadio-кадрах (NodeProbeTests), без Bluetooth. Сам разбор —
    /// в чистом NodeFactsParser (13.08): им же кормится ЖИВОЙ линк
    /// транспорта, чтобы профиль устройства был виден и в .yielded.
    @MainActor
    func ingest(_ bytes: [UInt8]) {
        var parser = NodeFactsParser(facts: facts, myNodeNum: myNodeNum,
                                     rawLoRa: rawLoRa)
        let complete = parser.ingest(bytes)
        facts = parser.facts
        myNodeNum = parser.myNodeNum
        rawLoRa = parser.rawLoRa
        if complete { finishIfReady() }
    }

    @MainActor
    private func finishIfReady() {
        timeoutTask?.cancel()
        phase = .ready
        // WP0: запомнить узел и сверить регионы — расхождение
        // неотличимо от бага отправки, молчать нельзя
        if let id = target?.identifier {
            rememberPeripheral(id)   // WP2: реконнект без скана
            NodeRegistry.record(id: id, name: facts.longName,
                                region: facts.region,
                                nodeCount: facts.nodeCount)
            regionWarnings = NodeRegistry.warnings(
                region: facts.region,
                expected: NodeRegistry.expectedRegion(),
                others: NodeRegistry.others(than: id))
            // пин протокола: чужая мажор.минор прошивки — вслух
            if let drift = NodeRegistry.firmwareWarning(
                firmware: facts.firmware) {
                regionWarnings.append(drift)
            }
        }
    }
}

/// Чистый разбор фактов узла из FromRadio-кадров (извлечение 13.08).
/// Два потребителя: NodeProbe (диагностика, фаза .ready) и ЖИВОЙ
/// MeshtasticLink (рабочая фаза .yielded — полевой регресс: профиль
/// «Имя —, Страна —» при работающем радиоканале, потому что факты
/// умел собирать только probe, а узел был у транспорта).
/// Номера полей — mesh.proto/config.proto (шапка NodeProbe, 02.08).
nonisolated struct NodeFactsParser {
    var facts: NodeProbe.NodeFacts
    var myNodeNum: UInt64?
    var rawLoRa: [UInt8]?

    init(facts: NodeProbe.NodeFacts = .init(),
         myNodeNum: UInt64? = nil, rawLoRa: [UInt8]? = nil) {
        self.facts = facts
        self.myNodeNum = myNodeNum
        self.rawLoRa = rawLoRa
    }

    /// Разобрать один кадр. true — пришёл config_complete_id (поток
    /// конфига дочитан, факты собраны).
    mutating func ingest(_ bytes: [UInt8]) -> Bool {
        let top = MiniProto.fields(bytes)
        if let myInfo = top[3]?.first {
            myNodeNum = MiniProto.fields(myInfo)[1]?.first
                .flatMap { MiniProto.readVarint($0) }
        }
        if let nodeInfo = top[4]?.first {
            facts.nodeCount += 1
            let f = MiniProto.fields(nodeInfo)
            let num = f[1]?.first.flatMap { MiniProto.readVarint($0) }
            if num == myNodeNum, let user = f[2]?.first,
               let longName = MiniProto.fields(user)[2]?.first {
                facts.longName = String(decoding: longName, as: UTF8.self)
            }
        }
        if let config = top[5]?.first,
           let lora = MiniProto.fields(config)[6]?.first {
            rawLoRa = lora
            if let region = MiniProto.fields(lora)[7]?.first
                .flatMap({ MiniProto.readVarint($0) }) {
                facts.region = NodeProbe.regionNames[region] ?? "код \(region)"
            }
        }
        if let metadata = top[13]?.first,
           let firmware = MiniProto.fields(metadata)[1]?.first {
            facts.firmware = String(decoding: firmware, as: UTF8.self)
        }
        return top[7]?.first != nil   // config_complete_id
    }
}
