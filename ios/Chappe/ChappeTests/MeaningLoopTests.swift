import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Смысловая петля на отправителе: детерминированные части (когда гонять,
// сборка промпта). Сквозной прогон с моделью — смоук на llama-server
// (tools-реплика, паритет кодека/матчера доказан тестами).
// ============================================================================

nonisolated struct MeaningLoopTests {

    private func encoded(rendered: String, units: [RMCodec.Unit])
    -> SemanticEncoder.Encoded {
        SemanticEncoder.Encoded(pivotRaw: "", pivot: "", units: units,
                                blob: [], rendered: rendered)
    }

    @Test("Латиница в рендере — петля нужна даже короткому")
    func latinTriggersLoop() {
        let e = encoded(rendered: "Мы leaving через 40 минут",
                        units: [.code(1), .lit("leaving")])
        #expect(SemanticEncoder.needsMeaningLoop(
            source: "мы выходим через 40 минут", encoded: e))
    }

    @Test("Чистый рендер: длиннее 15 слов — гонять, короче — нет")
    func lengthRule() {
        let clean = encoded(rendered: "Мы выходим через 40 минут",
                            units: [.code(1), .num(40)])
        let short = "мы выходим через 40 минут"
        #expect(!SemanticEncoder.needsMeaningLoop(source: short, encoded: clean))

        let long = Array(repeating: "слово", count: 16).joined(separator: " ")
        #expect(SemanticEncoder.needsMeaningLoop(source: long, encoded: clean))
    }

    @Test("Literal без латиницы (кириллический хвост) — тоже гонять")
    func litUnitTriggersLoop() {
        let e = encoded(rendered: "Мы каршеринг взяли",
                        units: [.lit("каршеринг"), .code(2)])
        #expect(SemanticEncoder.needsMeaningLoop(source: "мы каршеринг взяли",
                                                 encoded: e))
    }

    @Test("Промпт петли: оба текста внутри, порядок исходник→результат")
    func promptContainsBothTexts() throws {
        let p = SemanticEncoder.meaningLoopUserPrompt(
            source: "у нас закончились вода и хлеб",
            rendered: "мы бежать наружу вода хлеб")
        #expect(p.contains("Первый текст (исходник):\nу нас закончились вода и хлеб"))
        #expect(p.contains("Второй текст:\nмы бежать наружу вода хлеб"))
        let sourceIndex = try #require(p.range(of: "закончились")).lowerBound
        let renderedIndex = try #require(p.range(of: "бежать")).lowerBound
        #expect(sourceIndex < renderedIndex)
        // ключевые требования зашиты в системный промпт
        let sys = SemanticEncoder.meaningLoopSystemPrompt
        #expect(sys.contains("ran out = закончилось"))
        #expect(sys.contains("Не добавляй фактов"))
        #expect(sys.contains("потерял важный факт"))
    }
}
