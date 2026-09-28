import Foundation
import CoreBluetooth

// ============================================================================
// Мок Meshtastic-узла (трек BLE, Ф2). Запускается на Маке, прикидывается
// радиоузлом по BLE: тот же GATT-профиль и те же протобафы, что у живого
// железа, — приложение на iPhone подключается к нему как к настоящему.
//
// Профиль сверен по документации meshtastic.org/docs/development/device/
// client-api и meshtastic/protobufs mesh.proto + portnums.proto
// (снято 29-30.07.2026; версия зафиксирована в docs/reports/ble_bridge.md):
//   сервис    6ba1b218-15a8-461f-9fa8-5dcae273eafd
//   ToRadio   f75c76d2-129e-4dad-a1dd-7866124401e7  (write)
//   FromRadio 2c55e69e-4993-11ed-b878-0242ac120002  (read до пустого ответа)
//   FromNum   ed9da18c-a800-4f66-a670-aa7547e34453  (notify о новых пакетах)
//
// Умеет: принять пакет (ToRadio), вернуть подтверждение (routing-ack),
// отдать входящий (эхо полезной нагрузки — полный цикл с одним телефоном),
// сымитировать потерю (--loss) и задержку (--delay).
//
// Сборка и запуск:
//   swiftc -O tools/meshtastic_mock/main.swift -o /tmp/mesh_mock
//   /tmp/mesh_mock --loss 0.2 --delay 500
// ============================================================================

// MARK: - Мини-протобаф (копия субсета из MeshtasticLink.swift —
// CLI собирается отдельно от iOS-модуля)

enum Proto {
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

    static func varField(_ field: Int, _ value: UInt64) -> [UInt8] {
        value == 0 ? [] : key(field, wire: 0) + varint(value)
    }

    static func fields(_ bytes: [UInt8]) -> [Int: [[UInt8]]] {
        var out: [Int: [[UInt8]]] = [:]
        var i = 0
        while i < bytes.count {
            guard let (keyVal, keyLen) = readVarintAt(bytes, i) else { break }
            i += keyLen
            let field = Int(keyVal >> 3)
            switch Int(keyVal & 7) {
            case 0:
                guard let (v, l) = readVarintAt(bytes, i) else { return out }
                out[field, default: []].append(varint(v))
                i += l
            case 2:
                guard let (len, l) = readVarintAt(bytes, i) else { return out }
                i += l
                guard i + Int(len) <= bytes.count else { return out }
                out[field, default: []].append(Array(bytes[i..<i + Int(len)]))
                i += Int(len)
            case 5: i += 4
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

// MARK: - Параметры запуска

struct Options {
    var loss: Double = 0        // доля теряемых пакетов, 0..1
    var delayMs: Int = 0        // задержка перед ответом
    var echo = true             // эхо payload обратно как «входящий»
    var name = "RM-MOCK"        // имя периферии (peripheralName в конфиге)

    static func parse() -> Options {
        var o = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--loss": o.loss = Double(args.removeFirst()) ?? 0
            case "--delay": o.delayMs = Int(args.removeFirst()) ?? 0
            case "--no-echo": o.echo = false
            case "--name": o.name = args.removeFirst()
            default:
                print("параметры: [--loss 0.2] [--delay 500] [--no-echo] "
                      + "[--name RM-MOCK]")
                exit(1)
            }
        }
        return o
    }
}

// MARK: - Сам мок

final class MockNode: NSObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(
        string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    static let toRadioUUID = CBUUID(
        string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    static let fromRadioUUID = CBUUID(
        string: "2c55e69e-4993-11ed-b878-0242ac120002")
    static let fromNumUUID = CBUUID(
        string: "ed9da18c-a800-4f66-a670-aa7547e34453")

    let options: Options
    private var manager: CBPeripheralManager!
    private var fromNum: CBMutableCharacteristic!
    /// Очередь FromRadio: клиент читает по одному до пустого ответа.
    private var outQueue: [[UInt8]] = []
    private var packetCount: UInt32 = 0
    private var mockNodeNum: UInt64 = 0xA0A0_0001

    init(options: Options) {
        self.options = options
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            print("[мок] Bluetooth недоступен: state=\(peripheral.state.rawValue)")
            return
        }
        let toRadio = CBMutableCharacteristic(
            type: Self.toRadioUUID, properties: [.write],
            value: nil, permissions: [.writeable])
        let fromRadio = CBMutableCharacteristic(
            type: Self.fromRadioUUID, properties: [.read],
            value: nil, permissions: [.readable])
        fromNum = CBMutableCharacteristic(
            type: Self.fromNumUUID, properties: [.read, .notify],
            value: nil, permissions: [.readable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [toRadio, fromRadio, fromNum]
        manager.add(service)
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: options.name,
        ])
        print("[мок] в эфире как «\(options.name)», потеря \(options.loss), "
              + "задержка \(options.delayMs) мс, эхо \(options.echo ? "вкл" : "выкл")")
    }

    // Запись клиента в ToRadio
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let data = request.value { handleToRadio(Array(data)) }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    // Чтение клиента: FromRadio отдаёт по одному сообщению до пустого
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        switch request.characteristic.uuid {
        case Self.fromRadioUUID:
            let next = outQueue.isEmpty ? [] : outQueue.removeFirst()
            request.value = Data(next)
            peripheral.respond(to: request, withResult: .success)
            if !next.isEmpty {
                print("[мок] FromRadio → \(next.count) Б, в очереди \(outQueue.count)")
            }
        case Self.fromNumUUID:
            var n = packetCount.littleEndian
            request.value = Data(bytes: &n, count: 4)
            peripheral.respond(to: request, withResult: .success)
        default:
            peripheral.respond(to: request, withResult: .attributeNotFound)
        }
    }

    private func handleToRadio(_ bytes: [UInt8]) {
        let top = Proto.fields(bytes)
        // рукопожатие: want_config_id (поле 3) → config_complete_id (поле 7)
        if let nonce = top[3]?.first.flatMap({ Proto.readVarint($0) }) {
            print("[мок] want_config_id=\(nonce) → config_complete_id")
            push(Proto.varField(7, nonce))
            return
        }
        guard let mesh = top[1]?.first else {
            print("[мок] ToRadio без packet (\(bytes.count) Б) — пропускаю")
            return
        }
        let f = Proto.fields(mesh)
        let id = f[6]?.first.flatMap { Proto.readVarint($0) } ?? 0
        let decoded = f[4]?.first
        let portnum = decoded.flatMap {
            Proto.fields($0)[1]?.first.flatMap { Proto.readVarint($0) }
        } ?? 0
        let payload = decoded.flatMap { Proto.fields($0)[2]?.first } ?? []
        print("[мок] пакет id=\(id) portnum=\(portnum) payload=\(payload.count) Б")

        if Double.random(in: 0..<1) < options.loss {
            print("[мок] ...потерян (имитация эфира)")
            return
        }
        let work = { [self] in
            // подтверждение: routing-ack (portnum ROUTING_APP=5,
            // request_id=6 указывает на исходный пакет)
            let ackData = Proto.varField(1, 5)
                + Proto.lenField(2, [0x18, 0x00])   // Routing{error_reason=NONE}
                + Proto.varField(6, id)
            let ackMesh = Proto.varField(1, mockNodeNum)
                + Proto.lenField(4, ackData)
                + Proto.varField(6, UInt64.random(in: 1..<0xFFFF_FFFF))
            push(Proto.lenField(2, ackMesh))
            // входящий: эхо payload от «другого узла» — полный цикл
            // отправка → подтверждение → входящий с одним телефоном
            if options.echo, !payload.isEmpty {
                let echoData = Proto.varField(1, portnum)
                    + Proto.lenField(2, payload)
                let echoMesh = Proto.varField(1, mockNodeNum)
                    + Proto.lenField(4, echoData)
                    + Proto.varField(6, UInt64.random(in: 1..<0xFFFF_FFFF))
                push(Proto.lenField(2, echoMesh))
            }
        }
        if options.delayMs > 0 {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(options.delayMs),
                execute: work)
        } else {
            work()
        }
    }

    /// Положить FromRadio-сообщение в очередь и дёрнуть FromNum.
    private func push(_ fromRadio: [UInt8]) {
        outQueue.append(fromRadio)
        packetCount &+= 1
        var n = packetCount.littleEndian
        manager.updateValue(Data(bytes: &n, count: 4), for: fromNum,
                            onSubscribedCentrals: nil)
    }
}

let node = MockNode(options: Options.parse())
print("[мок] запускаюсь… (Ctrl+C — выход)")
RunLoop.main.run()
