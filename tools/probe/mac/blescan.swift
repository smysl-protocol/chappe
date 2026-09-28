import Foundation
import CoreBluetooth

// ============================================================================
// Mac-сторона пробы BLE (одноразовая, 06.08.2026). Три режима:
//   swift blescan.swift scan       — сканировать сервис пробника, печатать
//                                    рекламу (adv/overflow) с метками времени
//   swift blescan.swift scan-all   — сканировать ВСЁ и печатать сырые данные
//                                    рекламы телефона (что видит посторонний)
//   swift blescan.swift advertise  — рекламировать сервис пробника
//                                    (полная реклама переднего плана) и
//                                    принимать записи в inbox
// Требуется разрешение Bluetooth для терминала (диалог при первом запуске).
// ============================================================================

setvbuf(stdout, nil, _IONBF, 0)   // журнал без буферизации: годен для tail -f

let serviceUUID = CBUUID(string: "50524F42-4531-2026-0806-524D50524F42")
let inboxUUID = CBUUID(string: "50524F42-4532-2026-0806-524D50524F42")
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scan"

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

final class Scanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var manager: CBCentralManager!
    var lastSeen: [UUID: Date] = [:]
    var connectTarget: CBPeripheral?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[\(stamp())] central state \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        if mode == "scan-all" {
            central.scanForPeripherals(withServices: nil, options:
                [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            print("[\(stamp())] сканирую ВСЁ (сырой обзор постороннего)")
        } else {
            central.scanForPeripherals(withServices: [serviceUUID], options:
                [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            print("[\(stamp())] сканирую сервис \(serviceUUID)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey]
            as? String ?? peripheral.name ?? "-"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey]
            as? [CBUUID])?.map(\.uuidString) ?? []
        let overflow = (advertisementData["kCBAdvDataHashedServiceUUIDs"]
            as? [CBUUID])?.map(\.uuidString) ?? []
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey]
            as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
        // при scan-all печатаем только строки с чем-то интересным
        if mode == "scan-all" && services.isEmpty && overflow.isEmpty
            && mfg.isEmpty { return }
        let gap = lastSeen[peripheral.identifier].map {
            String(format: "+%.2fs", Date().timeIntervalSince($0))
        } ?? "новый"
        lastSeen[peripheral.identifier] = Date()
        print("[\(stamp())] \(peripheral.identifier.uuidString.prefix(8))"
            + " rssi=\(RSSI) name=\(name) adv=\(services)"
            + " overflow=\(overflow) mfg=\(mfg.prefix(40)) \(gap)")
        if mode == "connect", connectTarget == nil,
           services.contains(serviceUUID.uuidString)
            || overflow.contains(serviceUUID.uuidString) {
            connectTarget = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
            print("[\(stamp())] подключаюсь…")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        print("[\(stamp())] подключился, ищу сервис")
        peripheral.discoverServices([serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] where s.uuid == serviceUUID {
            peripheral.discoverCharacteristics([inboxUUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == inboxUUID {
            let text = "mac-ping \(stamp())"
            peripheral.writeValue(Data(text.utf8), for: c, type: .withResponse)
            print("[\(stamp())] записал «\(text)»")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        print("[\(stamp())] запись подтверждена: "
            + (error.map { "\($0)" } ?? "ok"))
    }
}

final class Beacon: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!

    func peripheralManagerDidUpdateState(_ m: CBPeripheralManager) {
        print("[\(stamp())] peripheral state \(m.state.rawValue)")
        guard m.state == .poweredOn else { return }
        let c = CBMutableCharacteristic(type: inboxUUID, properties: [.write],
                                        value: nil, permissions: [.writeable])
        let s = CBMutableService(type: serviceUUID, primary: true)
        s.characteristics = [c]
        m.add(s)
        m.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "mac-beacon",
        ])
        print("[\(stamp())] рекламирую \(serviceUUID)")
    }

    func peripheralManager(_ m: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let text = r.value.flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            print("[\(stamp())] ПРИНЯЛ: \(text)")
            m.respond(to: r, withResult: .success)
        }
    }
}

let scanner = Scanner()
let beacon = Beacon()
switch mode {
case "advertise":
    beacon.manager = CBPeripheralManager(delegate: beacon, queue: .main)
default:
    scanner.manager = CBCentralManager(delegate: scanner, queue: .main)
}
RunLoop.main.run()
