import Foundation
import CoreBluetooth
import UIKit
import UserNotifications

// ============================================================================
// Ядро пробника: одновременно периферал (рекламирует сервис) и централ
// (сканирует его же). Каждое событие — строка журнала с меткой времени,
// состоянием приложения (перед/фон) и остатком фонового времени.
// Журнал пишется в Documents/probe_log.jsonl СРАЗУ (замер переживает
// смерть приложения); снять с телефона:
//   xcrun devicectl device copy from --device <id> \
//     --domain-type appDataContainer --domain-identifier com.chappe.probe \
//     --source Documents/probe_log.jsonl --destination <куда>
// ============================================================================

final class ProbeCore: NSObject, ObservableObject {

    // Тот же UUID, что у BleLink продукта, НЕ используется — пробник
    // не должен цепляться за настоящие установки приложения.
    static let serviceUUID = CBUUID(
        string: "50524F42-4531-2026-0806-524D50524F42")
    static let inboxUUID = CBUUID(
        string: "50524F42-4532-2026-0806-524D50524F42")

    @Published var lines: [String] = []
    @Published var isAdvertising = false
    @Published var isScanning = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var connected: [UUID: CBPeripheral] = [:]
    private var lastSeen: [UUID: Date] = [:]
    private let logURL: URL = {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("probe_log.jsonl")
    }()

    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // пульс раз в 60 с: батарея, состояние — «наблюдатель обязан
        // иметь пульс» (правило 3 проекта); в фоне тикает, только пока
        // системе угодно держать процесс — сами пропуски пульса тоже
        // результат замера
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.log("pulse", detail: "")
        }
        log("probe_start", detail: "iOS \(UIDevice.current.systemVersion)")
    }

    // MARK: Управление (кнопки UI)

    func startBoth() {
        // restore identifier — проверка воскрешения приложения системой
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "probe-central"])
        peripheral = CBPeripheralManager(
            delegate: self, queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "probe-peripheral"])
        log("start_both", detail: "")
    }

    func stopAll() {
        central?.stopScan()
        peripheral?.stopAdvertising()
        central = nil
        peripheral = nil
        isScanning = false
        isAdvertising = false
        log("stop_all", detail: "")
    }

    // MARK: Журнал

    func log(_ event: String, detail: String) {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "?"
        }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingText = remaining > 100_000 ? "inf"
            : String(format: "%.1f", remaining)
        let battery = Int(UIDevice.current.batteryLevel * 100)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let record: [String: Any] = [
            "t": stamp, "event": event, "detail": detail,
            "app_state": state, "bg_remaining_s": remainingText,
            "battery_pct": battery,
            "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record),
           let line = String(data: data, encoding: .utf8) {
            appendToFile(line + "\n")
            DispatchQueue.main.async {
                self.lines.append("\(stamp.suffix(9)) [\(state)] \(event) \(detail)")
                if self.lines.count > 200 { self.lines.removeFirst(50) }
            }
        }
    }

    private func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private func notify(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Проба BLE"
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Централ: сканирование сервиса

extension ProbeCore: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central_state", detail: "\(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        // duplicates НЕ просим: в фоне iOS их всё равно глушит, а нам
        // важен факт и момент ПЕРВОГО обнаружения после появления
        central.scanForPeripherals(withServices: [Self.serviceUUID])
        DispatchQueue.main.async { self.isScanning = true }
        log("scan_start", detail: Self.serviceUUID.uuidString)
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        // сюда попадаем, если система воскресила приложение ради BLE
        log("central_restored", detail: "\(dict.keys.sorted())")
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let overflow = (advertisementData["kCBAdvDataHashedServiceUUIDs"]
            as? [CBUUID])?.isEmpty == false
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey]
            as? [CBUUID])?.isEmpty == false
        let gap = lastSeen[peripheral.identifier].map {
            String(format: "+%.1fs", Date().timeIntervalSince($0))
        } ?? "первый раз"
        lastSeen[peripheral.identifier] = Date()
        log("discover", detail: "rssi=\(RSSI) adv=\(advertised) "
            + "overflow=\(overflow) \(gap)")
        notify("Увидел соседа (rssi \(RSSI), \(gap))")
        // подключение: измеряем, успевает ли фон дойти до обмена
        guard connected[peripheral.identifier] == nil else { return }
        connected[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
        log("connect_request", detail: "")
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        log("connected", detail: "")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("connect_failed", detail: error.map { "\($0)" } ?? "?")
        connected[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("disconnected", detail: error.map { "\($0)" } ?? "штатно")
        connected[peripheral.identifier] = nil
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
            // маленький пакет «есть сообщения» — успевает ли за пробуждение
            let payload = "ping \(ISO8601DateFormatter().string(from: Date()))"
            peripheral.writeValue(Data(payload.utf8), for: characteristic,
                                  type: .withResponse)
            log("write_sent", detail: "\(payload.count) байт")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        log("write_confirmed", detail: error.map { "\($0)" } ?? "ok")
    }
}

// MARK: - Периферал: реклама сервиса и приём записей

extension ProbeCore: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        log("peripheral_state", detail: "\(manager.state.rawValue)")
        guard manager.state == .poweredOn else { return }
        let characteristic = CBMutableCharacteristic(
            type: Self.inboxUUID, properties: [.write],
            value: nil, permissions: [.writeable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        manager.removeAllServices()
        manager.add(service)
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "chappe-probe",
        ])
    }

    func peripheralManager(_ manager: CBPeripheralManager,
                           willRestoreState dict: [String: Any]) {
        log("peripheral_restored", detail: "\(dict.keys.sorted())")
    }

    func peripheralManagerDidStartAdvertising(_ manager: CBPeripheralManager,
                                              error: Error?) {
        DispatchQueue.main.async { self.isAdvertising = true }
        log("advertising", detail: error.map { "\($0)" } ?? "ok")
    }

    func peripheralManager(_ manager: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let text = request.value.flatMap {
                String(data: $0, encoding: .utf8)
            } ?? "?"
            log("write_received", detail: text)
            notify("Принял пакет: \(text)")
            manager.respond(to: request, withResult: .success)
        }
    }
}
