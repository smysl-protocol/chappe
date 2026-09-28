import Foundation
import Testing
@testable import Chappe

// ============================================================================
// B3: нарезка FRAG2 (шов, подпись владельца 11.08) — вектора независимого
// генератора + валидации приёмника + стрим-ассемблер.
//
// Гейт: FRAG2 СТРОГО при >255 кусков старой нарезки; ≤255 кусков ходят
// старым блоком u8 (потолок u8-пути v2 поднят 16 → 255 по подписанному
// тексту шва; v0/v1-путь TEXT остаётся с maxFragments=16).
// ============================================================================

nonisolated struct Frag2Tests {

    private func vectors() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/sealed_revb_vectors.json")
        return try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
    }

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    /// Ручной якорь из спеки: 23 20 | 34 12 | 01 00 | 2C 01 |
    /// 34 08 00 00 | AB CD (index 1, total 300, msg_len 2100).
    private let anchor = "2320341201002c0134080000abcd"

    @Test("FRAG2: нарезка побайтово с генератором, разбор сходится")
    func frag2VectorParity() throws {
        let v = try vectors()["frag2"] as! [String: Any]
        let stream = bytes(v["stream"] as! String)
        let frames = try EnvelopeV2.encodePackets(
            msgID: UInt16(v["msg_id"] as! Int), stream: stream,
            maxPayload: v["max_payload"] as! Int)
        #expect(frames.map { $0.map { String(format: "%02x", $0) }
            .joined() } == v["frames"] as! [String],
                "нарезка разошлась с независимым генератором")

        var chunks: [Int: [UInt8]] = [:]
        for frame in frames {
            let f = try EnvelopeV2.decode(frame)
            #expect(f.fragment == nil)
            let frag2 = try #require(f.frag2)
            #expect(frag2.total == v["total"] as! Int)
            #expect(frag2.msgLen == v["msg_len"] as! Int)
            chunks[frag2.index] = f.stream
        }
        let assembled = (0..<(v["total"] as! Int))
            .compactMap { chunks[$0] }.flatMap { $0 }
        #expect(assembled == stream)
    }

    @Test("Гейт: 255 старых кусков — блок u8; 256 — FRAG2")
    func gateBoundary() throws {
        let v = try vectors()["frag2_gate_boundary"] as! [String: Any]
        let mp = v["max_payload"] as! Int
        let edge = v["stream_len_old_path_max"] as! Int

        let old = try EnvelopeV2.encodePackets(
            msgID: 1, stream: [UInt8](repeating: 0, count: edge),
            maxPayload: mp)
        #expect(old.count == 255)
        let f = try EnvelopeV2.decode(old[254])
        #expect(f.fragment?.index == 254)
        #expect(f.fragment?.total == 255)
        #expect(f.frag2 == nil)

        let big = try EnvelopeV2.encodePackets(
            msgID: 1, stream: [UInt8](repeating: 0, count: edge + 1),
            maxPayload: mp)
        let f2 = try EnvelopeV2.decode(big[0])
        #expect(f2.fragment == nil)
        #expect(f2.frag2 != nil, "гейт обязан перешагнуть на FRAG2")
    }

    @Test("Разбор: якорь из спеки, потолки и взаимоисключение битов")
    func decodeCeilings() throws {
        let frame = bytes(anchor)
        let f = try EnvelopeV2.decode(frame)
        let frag2 = try #require(f.frag2)
        #expect(frag2.index == 1 && frag2.total == 300
                && frag2.msgLen == 2100)
        #expect(f.stream == [0xAB, 0xCD])

        func mutated(_ i: Int, _ b: UInt8) -> [UInt8] {
            var m = frame; m[i] = b; return m
        }
        // бит 0 вместе с битом 5
        #expect(throws: (any Error).self) {
            _ = try EnvelopeV2.decode(mutated(1, 0x21))
        }
        // бит 6 — по-прежнему ноль
        #expect(throws: (any Error).self) {
            _ = try EnvelopeV2.decode(mutated(1, 0x60))
        }
        // total 44 ≤ 255 — обязана старая нарезка (гейт на приёме)
        #expect(throws: (any Error).self) {
            _ = try EnvelopeV2.decode(mutated(7, 0x00))
        }
        // блок обрезан
        #expect(throws: (any Error).self) {
            _ = try EnvelopeV2.decode(Array(frame.prefix(6)))
        }
        // msg_len выше потолка 16 МиБ
        var over = frame
        over.replaceSubrange(8..<12, with: EnvelopeRevB.le32(16_777_217))
        #expect(throws: (any Error).self) {
            _ = try EnvelopeV2.decode(over)
        }
    }

    @Test("Ассемблер: стрим-выдача префикса, завершение, согласованность")
    func assemblerStreaming() throws {
        let chunks: [[UInt8]] = [[1, 2], [3, 4], [5], [6, 7]]
        let msgLen = 7, total = 256
        // сообщение «256 кусков», но пришли только первые 4 — префикс
        // обязан выдаваться по мере прихода НЕПРЕРЫВНОЙ части
        let asm = Frag2Assembler()
        // кусок 1 раньше нулевого: выдачи нет
        var e = try asm.add(msgID: 9, index: 1, total: total,
                            msgLen: msgLen, chunk: chunks[1])
        #expect(e.newBytes.isEmpty && !e.completed)
        // пришёл нулевой: выдаётся префикс 0+1
        e = try asm.add(msgID: 9, index: 0, total: total,
                        msgLen: msgLen, chunk: chunks[0])
        #expect(e.newBytes == [1, 2, 3, 4] && !e.completed)
        // дубликат игнорируется без повторной выдачи
        e = try asm.add(msgID: 9, index: 0, total: total,
                        msgLen: msgLen, chunk: chunks[0])
        #expect(e.newBytes.isEmpty && !e.completed)
        // кадр с несходящимся total — отбрасывается, сборка живёт
        #expect(throws: (any Error).self) {
            _ = try asm.add(msgID: 9, index: 2, total: 300,
                            msgLen: msgLen, chunk: chunks[2])
        }
        #expect(throws: (any Error).self) { // и с несходящимся msg_len
            _ = try asm.add(msgID: 9, index: 2, total: total,
                            msgLen: 99, chunk: chunks[2])
        }
        e = try asm.add(msgID: 9, index: 2, total: total,
                        msgLen: msgLen, chunk: chunks[2])
        #expect(e.newBytes == [5] && !e.completed)

        // полное сообщение из 2 кусков (total FRAG2 ≥ 256 — здесь
        // ассемблер общий, проверяем завершение и контроль длины)
        var done = try asm.add(msgID: 10, index: 0, total: 2,
                               msgLen: 3, chunk: [7, 8])
        #expect(!done.completed)
        done = try asm.add(msgID: 10, index: 1, total: 2,
                           msgLen: 3, chunk: [9])
        #expect(done.completed && done.stream == [7, 8, 9])

        // собранная длина ≠ msg_len — честная ошибка
        _ = try asm.add(msgID: 11, index: 0, total: 2, msgLen: 5,
                        chunk: [1])
        #expect(throws: (any Error).self) {
            _ = try asm.add(msgID: 11, index: 1, total: 2, msgLen: 5,
                            chunk: [2])
        }

        // таймаут: зависшая сборка вытесняется
        let timed = Frag2Assembler(timeout: 10)
        _ = try timed.add(msgID: 12, index: 0, total: 2, msgLen: 2,
                          chunk: [1], now: 0)
        _ = try timed.add(msgID: 13, index: 0, total: 2, msgLen: 2,
                          chunk: [1], now: 100)   // 12 протух
        #expect(timed.pendingCount == 1)
    }
}
