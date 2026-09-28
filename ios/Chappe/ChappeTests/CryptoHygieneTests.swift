import Foundation
import Testing
@testable import Chappe

// ============================================================================
// WP5 (бриф 05.08): гигиена криптокода. Тайминг тестом не измерить
// честно — здесь заперта СЕМАНТИКА constantTimeEqual (равенство,
// неравенство, разная длина) и невозможность нулевого сида рэтчета.
// Слом (возврат к ==, к игнору SecRandom) красит семантику лишь
// частично — сами свойства «константное время» держатся ревью кода,
// сказано честно в SECURITY.md.
// ============================================================================

struct CryptoHygieneTests {

    @Test("constantTimeEqual: семантика равенства")
    func constantTimeEqualSemantics() {
        let a: [UInt8] = [1, 2, 3, 4]
        #expect(Ratchet.constantTimeEqual(a, [1, 2, 3, 4]))
        #expect(!Ratchet.constantTimeEqual(a, [1, 2, 3, 5]))
        #expect(!Ratchet.constantTimeEqual(a, [2, 2, 3, 4]))
        #expect(!Ratchet.constantTimeEqual(a, [1, 2, 3]))
        #expect(Ratchet.constantTimeEqual([], []))
    }

    @Test("сид рэтчета: 32 байта, не нулевой, не повторяется")
    func ratchetSeedIsNeverZeroAndFresh() {
        let a = Outbox.randomSeed()
        let b = Outbox.randomSeed()
        #expect(a.count == 32)
        #expect(a.contains { $0 != 0 }, "нулевой сид — катастрофа шифрования")
        #expect(a != b, "сид обязан быть свежим на каждый вызов")
    }
}
