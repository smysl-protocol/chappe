import Foundation
import Testing
@testable import Chappe

// ============================================================================
// ЗАМКИ на пределы типов (аудит 03.08,
// docs/reports/type_limit_audit_2026-08-03.md).
//
// Найденная тихая порча: кодировщик пропускал phrase(128..255), но тег
// 0x80 занят маркером эмодзи — encode(phrase(128)) декодировался как
// ЭМОДЗИ, а следующий байт съедался, рассинхронизируя весь остаток
// потока. Валидные id фраз на проводе — только 0x00–0x7F
// (docs/rm_wire_bitspec.md §3).
// ============================================================================

nonisolated struct TypeLimitGuardTests {

    @Test("фраза 127 — последний валидный id, круг цел")
    func phrase127RoundTrips() throws {
        let codec = try #require(RMCodec.shared)
        let blob = try codec.encode([.phrase(127)])
        #expect(try codec.decode(blob) == [.phrase(127)])
    }

    @Test("фраза 128 обязана давать честный отказ, не эмодзи")
    func phrase128Throws() throws {
        let codec = try #require(RMCodec.shared)
        #expect(throws: (any Error).self) {
            _ = try codec.encode([.phrase(128)])
        }
    }

    @Test("расширение: 4094 кодируется, 4095 — резерв каскада, 4096 — отказ")
    func extBoundary() throws {
        // 4095 зарезервирован под будущий 16-битный каскад (решение
        // владельца 03.08, tools/semdict/ext_registry.json, спека §5.5):
        // кодировать нельзя, пока каскад не реализован. Декод остаётся
        // терпимым — примет и отрендерит заглушкой (совместимость).
        let codec = try #require(RMCodec.shared)
        let blob = try codec.encode([.ext(4094)])
        #expect(try codec.decode(blob) == [.ext(4094)])
        #expect(throws: (any Error).self) {
            _ = try codec.encode([.ext(4095)])
        }
        #expect(throws: (any Error).self) {
            _ = try codec.encode([.ext(4096)])
        }
    }
}
