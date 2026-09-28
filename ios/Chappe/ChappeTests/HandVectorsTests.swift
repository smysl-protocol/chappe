import Foundation
import Testing
@testable import Chappe

// ============================================================================
// РУЧНЫЕ ВЕКТОРА (решение владельца 03.08, часть II.3): разрыв
// замкнутого якоря корректности кодека.
//
// rm_codec_testvectors.json генерируется python-кодеком и при его
// ошибке Swift сверялся бы с ошибкой. tests/rm_hand_vectors.json
// посчитан ВРУЧНУЮ по docs/rm_wire_bitspec.md (вывод каждого вектора —
// в поле derivation) и НЕ перегенерируется никогда.
//
// РАСХОЖДЕНИЕ С ЭТИМ ФАЙЛОМ = ДЕФЕКТ КОДЕКА, не повод обновить вектор.
// ============================================================================

private func repoData(_ relative: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent(relative))
}

nonisolated struct HandVectorsTests {

    @Test("ручные вектора: encode и decode hex-в-hex")
    func handVectorsMatchByteForByte() throws {
        let codec = try #require(RMCodec.shared)
        let json = try JSONSerialization.jsonObject(
            with: repoData("tests/rm_hand_vectors.json")) as! [String: Any]
        #expect(json["dict_version"] as? String == codec.version,
                "словарь сменился — нужен новый файл векторов по новой спеке")

        for vector in json["vectors"] as! [[String: Any]] {
            let name = vector["name"] as! String
            let units = Self.parse(vector["units"] as! [[Any]])
            let expectedHex = vector["hex"] as! String

            let blob = try codec.encode(units)
            let gotHex = blob.map { String(format: "%02x", $0) }.joined()
            #expect(gotHex == expectedHex,
                    "\(name): encode дал \(gotHex), рука — \(expectedHex)")

            let decoded = try codec.decode(
                [UInt8](Self.bytes(fromHex: expectedHex)))
            #expect(decoded == units,
                    "\(name): decode разошёлся с юнитами вектора")
        }
    }

    @Test("отпечаток таблицы в файле совпадает с кодеком")
    func tableHashMatches() throws {
        let codec = try #require(RMCodec.shared)
        let json = try JSONSerialization.jsonObject(
            with: repoData("tests/rm_hand_vectors.json")) as! [String: Any]
        let wire = codec.wireBlob([]).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
        #expect(wire == json["table_hash_be"] as? String)
    }

    private static func parse(_ raw: [[Any]]) -> [RMCodec.Unit] {
        raw.map { pair in
            switch pair[0] as! String {
            case "code": return .code(pair[1] as! Int)
            case "num": return .num(pair[1] as! Int)
            case "lit": return .lit(pair[1] as! String)
            case "name": return .name(pair[1] as! String)
            case "emoji": return .emoji(pair[1] as! String)
            case "ext": return .ext(pair[1] as! Int)
            default: fatalError("вид юнита вне ручных векторов")
            }
        }
    }

    private static func bytes(fromHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }
}
