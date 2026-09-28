import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Замок round-trip (полевой блокер 11.08,
// docs/reports/semantic_roundtrip_gate.md): НИКОГДА не отправлять
// сообщение, чей декод у получателя ≠ вводу. Реконструкция — ровно
// приёмной функцией; разошлось — TEXT.
//
// Правило 4 CLAUDE.md: замок обязан падать на своём дефекте — верни
// roundTripGateReason nil, и полевой тест покраснеет.
// ============================================================================

nonisolated struct RoundTripGateTests {

    /// Дословный полевой ввод 11.08, ушедший «10 Б · 1 пакет» и
    /// приехавший двумя предложениями с добавленным смыслом.
    private let fieldInput = "почему сообщения идут так долго?"

    @Test("Полевой случай 11.08: декод ≠ вводу → замок шлёт текстом")
    func fieldCaseGoesToText() throws {
        let codec = try #require(RMCodec.shared)
        // Любой валидный словарный блоб: его развёртка — не полевая
        // фраза (вопрос в словаре дословно не живёт), значит замок
        // ОБЯЗАН дать причину. Если замок сломать (вернуть nil) —
        // тест красный.
        let blob = try codec.encode([.code(1)])
        let decoded = try TextCodec.decompress(
            codec.wireBlob(blob), codec: Envelope.codecSemantic)
        #expect(decoded != fieldInput,
                "фикстура: развёртка не должна совпадать с полевой фразой")
        #expect(SemanticEncoder.roundTripGateReason(
            source: fieldInput, blob: blob) != nil,
                "лоссовый блоб обязан уходить текстом")
    }

    @Test("Дословная реконструкция проходит замок")
    func verbatimRoundTripPasses() throws {
        let codec = try #require(RMCodec.shared)
        let blob = try codec.encode([.code(1)])
        // источник = ровно то, что увидит получатель — замок молчит
        let decoded = try TextCodec.decompress(
            codec.wireBlob(blob), codec: Envelope.codecSemantic)
        #expect(SemanticEncoder.roundTripGateReason(
            source: decoded, blob: blob) == nil)
        // а любое отклонение от дословности — причина
        #expect(SemanticEncoder.roundTripGateReason(
            source: decoded + " хвост", blob: blob) != nil)
    }

    @Test("finish(): расхождение round-trip даёт исход .text с карточкой")
    func finishFallsBackToText() throws {
        let codec = try #require(RMCodec.shared)
        let blob = try codec.encode([.code(1)])
        let encoded = SemanticEncoder.Encoded(
            pivotRaw: fieldInput, pivot: fieldInput,
            units: [.code(1)], blob: blob,
            rendered: codec.render([.code(1)]))
        guard case .text(_, let needsCard) =
                SemanticEncoder.finish(encoded, source: fieldInput) else {
            Issue.record("расхождение обязано уходить текстом")
            return
        }
        #expect(needsCard, "честная карточка «сжатие не подходит»")
    }
}
