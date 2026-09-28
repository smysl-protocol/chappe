import Foundation
import Testing
@testable import Chappe

// ============================================================================
// ЗАМОК на типы полей ToRadio (поймано на первом живом радиотесте 02.08).
//
// MeshPacket.to и .id — fixed32 (wire 5). Пока они писались varint'ом
// (wire 0), узел НЕ мог разобрать ToRadio и молча выбрасывал пакет,
// а BLE-запись при этом проходила успешно — приложение показывало
// «отправлено», в эфир не уходило ничего, и по экрану это было
// неотличимо от проблем радио. Полдня ушло на поиск.
// ============================================================================

nonisolated struct MeshWireTypeTests {

    /// Разбирает ключ поля: (номер, тип провода).
    private func keys(_ bytes: [UInt8]) -> [(field: Int, wire: Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        while i < bytes.count {
            var value = 0, shift = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                value |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { break }
                shift += 7
            }
            let field = value >> 3, wire = value & 7
            out.append((field, wire))
            switch wire {
            case 0:
                while i < bytes.count, bytes[i] & 0x80 != 0 { i += 1 }
                i += 1
            case 2:
                var len = 0, s = 0
                while i < bytes.count {
                    let b = bytes[i]; i += 1
                    len |= Int(b & 0x7F) << s
                    if b & 0x80 == 0 { break }
                    s += 7
                }
                i += len
            case 5: i += 4
            case 1: i += 8
            default: i = bytes.count
            }
        }
        return out
    }

    @Test("ToRadio: to и id идут fixed32, а не varint")
    func destinationAndIDAreFixed32() throws {
        let frame = MiniProto.toRadio(payload: [1, 2, 3],
                                           packetID: 0x11223344)
        // ToRadio { packet = 1 }
        let outer = keys(frame)
        #expect(outer.first?.field == 1)
        #expect(outer.first?.wire == 2)

        // внутренность MeshPacket
        var i = 0
        var value = 0, shift = 0
        while i < frame.count {
            let b = frame[i]; i += 1
            value |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        var len = 0; shift = 0
        while i < frame.count {
            let b = frame[i]; i += 1
            len |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        let mesh = Array(frame[i..<(i + len)])
        let fields = keys(mesh)

        let to = try #require(fields.first { $0.field == 2 })
        #expect(to.wire == 5, "MeshPacket.to обязан быть fixed32")
        let id = try #require(fields.first { $0.field == 6 })
        #expect(id.wire == 5, "MeshPacket.id обязан быть fixed32")
        let data = try #require(fields.first { $0.field == 4 })
        #expect(data.wire == 2, "decoded — вложенное сообщение")
        let wantAck = try #require(fields.first { $0.field == 10 })
        #expect(wantAck.wire == 0, "want_ack — bool, varint")
    }

    @Test("golden: байты ToRadio стабильны")
    func goldenToRadio() {
        let frame = MiniProto.toRadio(payload: [0xAA],
                                           packetID: 0x04030201,
                                           portnum: 256,
                                           to: 0xFFFFFFFF)
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        // 0a … packet; 15 ffffffff → to fixed32; 22 04 0880021201aa → Data;
        // 35 01020304 → id fixed32; 50 01 → want_ack
        // эталон посчитан отдельным python-скриптом, вне Swift
        #expect(hex == "0a1415ffffffff22060880021201aa35010203045001")
    }
}
