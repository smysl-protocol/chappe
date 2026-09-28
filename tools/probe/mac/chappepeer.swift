import Foundation
import CoreBluetooth

// ============================================================================
// Второй конец «рядом» на Маке (проверка фазы 1, 07.08).
//
// Зачем: macOS не запускает iOS-приложение вне Xcode (процесс убивают,
// диалог «damaged»), а симулятор не имеет настоящего Bluetooth. Поэтому
// вторым собеседником работает эта утилита: она говорит ТЕМ ЖЕ проводом,
// что продукт (service/characteristic UUID и формат фрагментов BleLink,
// заголовок конверта Envelope), но не является приложением.
//
// Честная граница: это НЕ два продуктовых экземпляра. Проверяется всё,
// что видит провод: обнаружение, веер, фрагментация/сборка, приём
// конверта телефоном, подтверждение доставки (ACK) и отметка прочтения.
// Смысловая расшифровка на стороне Мака не делается — ключей нет.
//
// Режимы:
//   peer      — маяк + приём: рекламирует сервис, принимает записи,
//               собирает фрагменты, печатает разбор заголовка конверта
//               и на сообщение с запросом подтверждения отвечает ACK;
//   ackonly   — то же, но без ответа (проверка «ждёт подтверждения»).
// ============================================================================

setvbuf(stdout, nil, _IONBF, 0)

let serviceUUID = CBUUID(string: "524D0001-5359-534C-524D-30303153594C")
let inboxUUID = CBUUID(string: "524D0002-5359-534C-524D-30303253594C")
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "peer"

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// — формат провода (зеркало Envelope.swift; менять только вместе с ним) —
let classSOS: UInt8 = 0x1, classBeacon: UInt8 = 0x2, classText: UInt8 = 0x3
let classAck: UInt8 = 0x4, classLocation: UInt8 = 0x5, classRead: UInt8 = 0x6
let envelopeVersion: UInt8 = 1
let flagAckRequest: UInt8 = 1 << 1

func envelopeClassName(_ code: UInt8) -> String {
    switch code {
    case classSOS: "SOS"
    case classBeacon: "маяк"
    case classText: "сообщение"
    case classAck: "подтверждение"
    case classLocation: "координаты"
    case classRead: "прочитано"
    default: "класс \(code)"
    }
}

func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

func ackPacket(for ackMsgID: UInt16, myMsgID: UInt16) -> [UInt8] {
    [(envelopeVersion << 4) | classAck, 0] + le16(myMsgID) + le16(ackMsgID)
}

/// Фрагментация — точная копия BleLink.fragment: [tag][index][total][кусок].
func fragment(_ packet: [UInt8], mtu: Int, tag: UInt8) -> [[UInt8]] {
    let chunkSize = max(mtu - 3, 1)
    var out: [[UInt8]] = []
    let total = (packet.count + chunkSize - 1) / chunkSize
    var i = 0
    while i < packet.count {
        let end = min(i + chunkSize, packet.count)
        out.append([tag, UInt8(out.count), UInt8(min(total, 255))]
                   + packet[i..<end])
        i = end
    }
    return out.isEmpty ? [[tag, 0, 1]] : out
}

final class Peer: NSObject, CBPeripheralManagerDelegate,
                  CBCentralManagerDelegate, CBPeripheralDelegate {

    var manager: CBPeripheralManager!
    var central: CBCentralManager!
    /// сборка входящих: tag → (total, куски)
    var assembly: [UInt8: (total: Int, chunks: [Int: [UInt8]])] = [:]
    /// подключение обратно (для ACK): телефон как периферал
    var phone: CBPeripheral?
    var phoneInbox: CBCharacteristic?
    var pendingAcks: [UInt16] = []
    var nextMsgID: UInt16 = 0xA000
    var received = 0

    // MARK: приём (мы — периферал, телефон пишет нам)

    func peripheralManagerDidUpdateState(_ m: CBPeripheralManager) {
        guard m.state == .poweredOn else {
            print("[\(stamp())] Bluetooth недоступен (\(m.state.rawValue))")
            return
        }
        let inbox = CBMutableCharacteristic(
            type: inboxUUID, properties: [.write, .writeWithoutResponse],
            value: nil, permissions: [.writeable])
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [inbox]
        m.removeAllServices()
        m.add(service)
        m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
        print("[\(stamp())] рекламирую сервис Chappe, жду собеседника")
        // одновременно ищем телефон, чтобы было куда слать ACK
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func peripheralManager(_ m: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let data = request.value else { continue }
            let frag = Array(data)
            guard frag.count >= 3 else { continue }
            let tag = frag[0], index = Int(frag[1]), total = Int(frag[2])
            var record = assembly[tag] ?? (total, [:])
            if record.total != total { record = (total, [:]) }
            record.chunks[index] = Array(frag.dropFirst(3))
            assembly[tag] = record
            print("[\(stamp())] фрагмент tag=\(tag) \(index + 1)/\(total) "
                + "(\(frag.count - 3) Б)")
            if record.chunks.count == total {
                assembly[tag] = nil
                let whole = (0..<total).compactMap { record.chunks[$0] }
                    .flatMap { $0 }
                handleWhole(whole)
            }
            if request.characteristic.properties.contains(.write) {
                m.respond(to: request, withResult: .success)
            }
        }
    }

    func handleWhole(_ packet: [UInt8]) {
        received += 1
        guard packet.count >= 4 else { return }
        let cls = packet[0] & 0x0F, ver = packet[0] >> 4, flags = packet[1]
        let msgID = UInt16(packet[2]) | UInt16(packet[3]) << 8
        print("[\(stamp())] ПРИНЯЛ ЦЕЛИКОМ: \(packet.count) Б · "
            + "v\(ver) \(envelopeClassName(cls)) msgID=\(msgID) flags=\(flags) · "
            + hex(Array(packet.prefix(24))) + (packet.count > 24 ? "…" : ""))
        // подтверждаем только то, что просит подтверждения
        if mode == "peer", flags & flagAckRequest != 0 || cls == classText {
            pendingAcks.append(msgID)
            sendPendingAcks()
        }
    }

    // MARK: обратная сторона (мы — централ, пишем телефону ACK)

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [serviceUUID])
        print("[\(stamp())] ищу телефон для обратного канала")
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard phone == nil else { return }
        phone = p
        p.delegate = self
        c.connect(p)
        print("[\(stamp())] нашёл телефон (rssi \(rssi)), подключаюсь")
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager,
                        didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("[\(stamp())] обратный канал разорван, ищу снова")
        phone = nil; phoneInbox = nil
        c.scanForPeripherals(withServices: [serviceUUID])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == serviceUUID {
            p.discoverCharacteristics([inboxUUID], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral,
                    didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] where c.uuid == inboxUUID {
            phoneInbox = c
            print("[\(stamp())] обратный канал готов")
            sendPendingAcks()
        }
    }

    func sendPendingAcks() {
        guard let phone, let inbox = phoneInbox, !pendingAcks.isEmpty else {
            return
        }
        let acks = pendingAcks
        pendingAcks.removeAll()
        for id in acks {
            nextMsgID &+= 1
            let packet = ackPacket(for: id, myMsgID: nextMsgID)
            let mtu = max(phone.maximumWriteValueLength(for: .withResponse) - 3, 20)
            for chunk in fragment(packet, mtu: mtu, tag: UInt8(nextMsgID & 0xFF)) {
                phone.writeValue(Data(chunk), for: inbox, type: .withResponse)
            }
            print("[\(stamp())] ОТПРАВИЛ подтверждение на msgID=\(id): "
                + hex(packet))
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic,
                    error: Error?) {
        print("[\(stamp())] запись подтверждена: \(error.map { "\($0)" } ?? "ok")")
    }
}

let peer = Peer()
peer.manager = CBPeripheralManager(delegate: peer, queue: .main)
RunLoop.main.run()
