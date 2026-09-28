import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Residual-счётчик (semantic_compression §6): literal-слова копятся,
// имена и числа — нет, экспорт — валидный JSON.
//
// Тесты хостятся в приложении и делят один файл в Application Support,
// поэтому каждый тест начинается и заканчивается reset(); сериализованы,
// чтобы не топтать состояние друг друга.
// ============================================================================

@Suite("Residual-счётчик", .serialized)
nonisolated struct ResidualCounterTests {

    // MARK: Извлечение слов из юнитов

    @Test("Только literal-слова, нормализация как в матчере")
    func literalWordExtraction() {
        let units: [RMCodec.Unit] = [
            .code(3),
            .lit("Каршеринг, каршеринг — ДЁШЕВО!"),
            .name("Касабланка"),
            .num(15),
            .lit("байк"),
        ]
        let words = ResidualCounter.literalWords(units)
        #expect(words == ["каршеринг", "дёшево", "байк"])
    }

    @Test("Имена и числа в счётчик не попадают")
    func namesAndNumbersExcluded() {
        ResidualCounter.reset()
        defer { ResidualCounter.reset() }

        ResidualCounter.record(units: [
            .name("Пхукет"),
            .num(42),
            .lit("серфинг 7 раз"),   // цифры внутри literal — тоже мимо
        ])
        let counts = ResidualCounter.load()
        #expect(counts == ["серфинг": 1, "раз": 1])
    }

    @Test("Счётчик копится по отправкам: слово 1 раз на отправку")
    func countsAccumulatePerSend() {
        ResidualCounter.reset()
        defer { ResidualCounter.reset() }

        // одна отправка: «шторм» дважды в тексте — считается один раз
        ResidualCounter.record(units: [.lit("шторм близко, шторм сильный")])
        ResidualCounter.record(units: [.lit("шторм ушёл")])
        ResidualCounter.record(units: [.lit("байк сломался")])

        let counts = ResidualCounter.load()
        #expect(counts["шторм"] == 2)
        #expect(counts["байк"] == 1)

        let top = ResidualCounter.top(1)
        let first = top.first
        #expect(first?.word == "шторм")
        #expect(first?.count == 2)
    }

    @Test("Пустой список literal-слов ничего не пишет")
    func emptyRecordIsNoop() {
        ResidualCounter.reset()
        defer { ResidualCounter.reset() }

        ResidualCounter.record(units: [.name("Убуд"), .num(3), .code(7)])
        #expect(ResidualCounter.load().isEmpty)
    }

    // MARK: Экспорт

    @Test("Экспорт — валидный JSON со словами")
    func exportIsValidJSON() throws {
        ResidualCounter.reset()
        defer { ResidualCounter.reset() }

        ResidualCounter.record(units: [.lit("генератор дизель")])
        let url = try ResidualCounter.exportJSON()
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(object as? [String: Any])
        let words = try #require(dict["words"] as? [String: Int])
        #expect(words == ["генератор": 1, "дизель": 1])
    }
}
