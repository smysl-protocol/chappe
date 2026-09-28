//
//  SophiePromptTests.swift
//  RMTests
//
//  Сборка промпта Софи: окно с бюджетом токенов, формат расшифровки,
//  системный промпт из бандла.
//

import Foundation
import Testing
@testable import Chappe

struct SophiePromptTests {

    private func message(_ role: SophieMessage.Role, _ text: String) -> SophieMessage {
        SophieMessage(role: role, text: text)
    }

    /// Окно берёт самые свежие сообщения и не превышает бюджет.
    @Test func windowRespectsBudgetKeepingNewest() {
        // Каждое сообщение ~100 символов ≈ 33+8 оценочных токена
        let history = (0..<200).map {
            message($0 % 2 == 0 ? .user : .sophie,
                    "сообщение номер \($0) " + String(repeating: "х", count: 80))
        }
        let window = SophiePrompt.window(history, budget: 300)

        #expect(!window.isEmpty)
        #expect(window.count < history.count, "окно обязано отрезать старое")
        #expect(window.last?.id == history.last?.id, "самое свежее — всегда в окне")
        // Порядок сохранён и это точный хвост истории
        #expect(window.map(\.id) == history.suffix(window.count).map(\.id))
        // Бюджет соблюдён
        let cost = window.reduce(0) { $0 + SophiePrompt.estimatedTokens($1.text) + 8 }
        #expect(cost <= 300, "стоимость окна \(cost) больше бюджета")
    }

    /// Пустая история — окно пустое, промпт содержит только новое сообщение.
    @Test func emptyHistoryProducesBareUserPrompt() {
        let window = SophiePrompt.window([])
        #expect(window.isEmpty)
        let prompt = SophiePrompt.userPrompt(window: window, newText: "привет")
        #expect(prompt == "Пользователь: привет")
    }

    /// Формат расшифровки: роли размечены, новое сообщение — последней строкой.
    @Test func transcriptFormat() {
        let history = [message(.user, "где ты"), message(.sophie, "не знаю")]
        let prompt = SophiePrompt.userPrompt(window: history, newText: "ладно")
        #expect(prompt == "Пользователь: где ты\nСофи: не знаю\nПользователь: ладно")
    }

    /// Одно гигантское сообщение больше бюджета — окно пустое (без обрезки
    /// посередине), промпт не взрывается.
    @Test func oversizeMessageIsDroppedWhole() {
        let history = [message(.user, String(repeating: "х", count: 20_000))]
        let window = SophiePrompt.window(history, budget: 300)
        #expect(window.isEmpty)
    }

    /// Системный промпт Софи (v1) лежит в бандле и содержит ключевые правила.
    @Test func systemPromptLoadsFromBundle() throws {
        let system = try SophiePrompt.systemPrompt()
        #expect(system.contains("Софи"))
        #expect(system.contains("скажи прямо"), "честное незнание — в промпте")
        #expect(system.contains("выдумыва"),
                "запрет выдумывать функции и цифры")
        #expect(system.contains("Позиций собеседников"),
                "честная строка про отсутствие позиций собеседников (фаза 2а)")
        #expect(system.contains("дозировк"), "запрет дозировок сохранён")
    }

    /// Род ассистента (Ф1-доп, 30.07): живой баг «я ошибся» + «стараюсь
    /// быть точной» в одном ответе. Промпт обязан нести женский род
    /// явно, с примерами форм и запретом мужских. Живые фикстуры —
    /// tools/bench_gender.py (llama-server); здесь — защита от
    /// регресса при правках персоны.
    // Поле 22.08 (скрин владельца): Софи в самоописании отрекалась от
    // погоды, хотя инструмент weather уже отдаёт офлайн-прогноз. Промпт
    // не должен противоречить возможностям (слом: вернуть «не знаешь
    // погоды» — красный).
    @Test func systemPromptDoesNotDisownWeather() throws {
        let system = try SophiePrompt.systemPrompt()
        #expect(!system.contains("новостей, погоды"), Comment(rawValue:
                "запрет погоды устарел: инструмент weather читает "
                + "скачанный пак — самоописание не должно врать"))
        #expect(system.lowercased().contains("погод"),
                "погода упомянута позитивно: откуда берётся и что офлайн")
    }

    @Test func systemPromptFixesFeminineGender() throws {
        let system = try SophiePrompt.systemPrompt()
        #expect(system.contains("женском роде"))
        for form in ["ошиблась", "поняла", "нашла", "уверена",
                     "готова", "рада", "точна"] {
            #expect(system.contains(form), "нет женской формы «\(form)»")
        }
        #expect(system.contains("недопустимы"),
                "запрет мужских форм должен быть явным")
        #expect(system.contains("во всех языках"),
                "правило распространяется на все языки с родом")
    }
}
