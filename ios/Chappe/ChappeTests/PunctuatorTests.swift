import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Пунктуатор Ф2: граница = заглавная И разрыв; имя в середине фразы —
// не граница; тип терминала по Б6 (ru-стартеры v1.1); голосовые
// команды; работа без модели (детерминированный код).
// ============================================================================

private func words(_ items: [(String, Double, Double)]) -> [Punctuator.Word] {
    items.map { Punctuator.Word(text: $0.0, start: $0.1, duration: $0.2) }
}

/// Слова подряд без пауз, шаг 0.3 с, с задаваемого старта.
private func flow(_ text: String, from: Double = 0) -> [Punctuator.Word] {
    text.split(separator: " ").enumerated().map { i, w in
        Punctuator.Word(text: String(w), start: from + Double(i) * 0.3,
                        duration: 0.28)
    }
}

nonisolated struct PunctuatorTests {

    @Test("Граница = заглавная И разрыв одновременно")
    func boundaryNeedsBothSignals() {
        // два предложения: разрыв 1.2 с + заглавная «Погода»
        let f = flow("мы вышли на рассвете") +
                flow("Погода испортилась", from: 2.5)
        let out = Punctuator.punctuate(finals: [f], pauseThreshold: 0.7)
        #expect(out == "Мы вышли на рассвете. Погода испортилась.")
    }

    @Test("Разрыв без заглавной — не граница (запинка)")
    func gapAloneIsNotBoundary() {
        let f = flow("мы вышли на") + flow("рассвете рано", from: 2.5)
        let out = Punctuator.punctuate(finals: [f], pauseThreshold: 0.7)
        #expect(out == "Мы вышли на рассвете рано.")
    }

    @Test("Имя в середине фразы — не граница (бриф: Марина, Андрей)")
    func capitalizedNameIsNotBoundary() {
        // «Марина» и «Андрей» с заглавной, но БЕЗ разрыва — фраза цела
        let f = flow("передай Марина что мы ждём и скажи Андрей взять воду")
        let out = Punctuator.punctuate(finals: [f], pauseThreshold: 0.7)
        #expect(out == "Передай Марина что мы ждём и скажи Андрей взять воду.")
        #expect(!out.contains(". Марина"))
        #expect(!out.contains(". Андрей"))
    }

    @Test("Между финалами распознавателя — граница всегда")
    func finalsAreBoundaries() {
        let out = Punctuator.punctuate(
            finals: [flow("мы дошли до перевала"),
                     flow("вода в ручье чистая", from: 10)],
            pauseThreshold: 0.7)
        #expect(out == "Мы дошли до перевала. Вода в ручье чистая.")
    }

    @Test("Б6: вопросительный стартер даёт «?», не точку")
    func questionStarterGivesQuestionMark() {
        let out = Punctuator.punctuate(
            finals: [flow("где вы сейчас"),
                     flow("сколько у вас воды", from: 5),
                     flow("мы у моста", from: 10)],
            pauseThreshold: 0.7)
        #expect(out == "Где вы сейчас? Сколько у вас воды? Мы у моста.")
        // список — один, из PivotMatcher (не копия)
        #expect(PivotMatcher.questionStartersRu.contains("где"))
    }

    @Test("Голосовые команды: точка, запятая, знак вопроса, новая строка")
    func voiceCommands() {
        #expect(Punctuator.punctuate(
            finals: [flow("идём дальше точка привал у скалы")],
            pauseThreshold: 0.7)
            == "Идём дальше. Привал у скалы.")
        #expect(Punctuator.punctuate(
            finals: [flow("возьми воду запятая хлеб и батареи")],
            pauseThreshold: 0.7)
            == "Возьми воду, хлеб и батареи.")
        #expect(Punctuator.punctuate(
            finals: [flow("ты взял рацию знак вопроса жду ответа")],
            pauseThreshold: 0.7)
            == "Ты взял рацию? Жду ответа.")
        let lines = Punctuator.punctuate(
            finals: [flow("первый пункт новая строка второй пункт")],
            pauseThreshold: 0.7)
        #expect(lines == "Первый пункт\nВторой пункт.")
    }

    @Test("Порог паузы читается из конфига")
    func thresholdIsConfigurable() {
        // гэп 0.5: при пороге 0.7 — не граница, при 0.4 — граница
        let f = flow("мы вышли рано") + flow("Погода злая", from: 1.36)
        #expect(Punctuator.punctuate(finals: [f], pauseThreshold: 0.7)
                == "Мы вышли рано Погода злая.")
        #expect(Punctuator.punctuate(finals: [f], pauseThreshold: 0.4)
                == "Мы вышли рано. Погода злая.")
    }

    @Test("2.5: пунктуатор — чистый код, живёт без модели и до гейта")
    func worksWithoutModel() {
        // Никакого ModelScheduler: обычный вызов на пустых дефолтах —
        // детерминированный результат независимо от установленной модели
        let out = Punctuator.punctuate(
            finals: [flow("проверка без модели")], pauseThreshold: 0.7)
        #expect(out == "Проверка без модели.")
        #expect(!Punctuator.commandsHint.isEmpty)
    }
}
