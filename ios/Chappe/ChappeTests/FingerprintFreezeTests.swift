import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Замок отпечатков перед заморозкой (WP6, 02.08). Основной словарь
// сторожит DictFreezeV1Tests (4 байта с 03.08); здесь — litchars-таблица, которую
// провод-байт НЕ покрывает: её разъезд ловится только этим тестом и
// tools/semdict/check_fingerprints.py (эталон 0xC3 там же).
// ============================================================================

nonisolated struct FingerprintFreezeTests {

    @Test("litchars v1.2: отпечаток канонических длин = 0xC3")
    func litcharsFingerprintFrozen() throws {
        let codec = try #require(RMCodec.shared)
        // FNV-1a 32 по «cp:bits;» в порядке роста cp — синхронно с
        // check_fingerprints.py
        var h: UInt32 = 0x811C9DC5
        for (cp, bv) in codec.charEnc.sorted(by: { $0.key < $1.key }) {
            for byte in "\(cp):\(bv.bits);".utf8 {
                h = (h ^ UInt32(byte)) &* 0x01000193
            }
        }
        #expect(UInt8(h & 0xFF) == 0xC3,
                "litchars-отпечаток уплыл: 0x\(String(h & 0xFF, radix: 16))")
        #expect(codec.charEnc.count == 86)
    }

    // 03.08: словарь дополнен 24 записями обиходной координации по
    // замеру живого трафика (74% → 94% срабатываний кодека), версия
    // 1.3.0, отпечаток пересчитан. Замок сохраняет смысл: любое
    // НЕОБЪЯВЛЕННОЕ изменение словаря обязано ронять этот тест.
    @Test("отпечаток провода = 0x883E14BE (словарь+litchars), версия 1.3.0")
    func dictionaryFingerprintFrozen() throws {
        let codec = try #require(RMCodec.shared)
        #expect(codec.tableHash == 0x883E14BE)
        #expect(codec.version == "1.3.0")
    }
}
