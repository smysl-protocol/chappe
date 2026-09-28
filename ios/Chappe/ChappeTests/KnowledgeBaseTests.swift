//
//  KnowledgeBaseTests.swift
//  RMTests
//
//  Ретривер баз знаний по docs/kb_spec.md: нужная секция по запросу,
//  бюджет, пустой матч → ядро + оглавление, детерминизм, сборка
//  промпта пресет-чата.
//

import Foundation
import Testing
@testable import Chappe

struct KnowledgeBaseTests {

    /// «кровь не останавливается» → секция «Сильное кровотечение»
    /// из реального пака первой помощи в бандле.
    @Test func bleedingQueryFindsBleedingSection() throws {
        let base = try KnowledgeBase.load(file: SophiePreset.firstAid.kbFile)
        let picked = KnowledgeRetriever.select(from: base,
                                               query: "кровь не останавливается")
        let hasCore = picked.contains { $0.isCore }
        let hasBleeding = picked.contains { $0.title == "Сильное кровотечение" }
        let hasTOC = picked.contains { $0.isTOC }
        #expect(hasCore, "ядро — всегда")
        #expect(hasBleeding, "нашлись: \(picked.map(\.title))")
        #expect(!hasTOC, "оглавление — только при нуле совпадений")
    }

    /// Бюджет ~1200 оценочных токенов не превышается (ядро вне лимита не режем,
    /// добор секций — в пределах).
    @Test func budgetIsRespected() throws {
        let base = try KnowledgeBase.load(file: SophiePreset.firstAid.kbFile)
        // Запрос, цепляющий много секций сразу
        let picked = KnowledgeRetriever.select(
            from: base,
            query: "кровь перелом ожог жара холод змея без сознания не дышит рана")
        let total = picked.reduce(0) { $0 + KnowledgeRetriever.estimatedTokens($1.body) }
        #expect(total <= KnowledgeRetriever.tokenBudget + 400,
                "суммарно \(total) ток. при бюджете \(KnowledgeRetriever.tokenBudget)")
        #expect(picked.count > 2, "широкий запрос обязан набрать несколько секций")
    }

    /// Ноль совпадений → ядро + «Оглавление» (Софи говорит, о чём умеет).
    @Test func noMatchGivesCoreAndTOC() throws {
        let base = try KnowledgeBase.load(file: SophiePreset.about.kbFile)
        let picked = KnowledgeRetriever.select(from: base,
                                               query: "квантовая хромодинамика")
        #expect(picked.count == 2)
        #expect(picked[0].isCore)
        #expect(picked[1].isTOC)
    }

    /// Выборка детерминирована: один запрос → один результат.
    @Test func selectionIsDeterministic() throws {
        let base = try KnowledgeBase.load(file: SophiePreset.comms.kbFile)
        let a = KnowledgeRetriever.select(from: base, query: "почему не доходит сообщение")
        let b = KnowledgeRetriever.select(from: base, query: "почему не доходит сообщение")
        #expect(a == b)
    }

    /// Правило матча: ключ ≥4 — префикс слова; короткий ключ — только целиком.
    @Test func prefixMatchRules() {
        #expect(KnowledgeRetriever.matches(key: "кровотеч", word: "кровотечение"))
        #expect(KnowledgeRetriever.matches(key: "жгут", word: "жгут"))
        #expect(KnowledgeRetriever.matches(key: "sos", word: "sos"))
        #expect(!KnowledgeRetriever.matches(key: "sos", word: "сосед"),
                "короткий ключ не должен ловить чужие слова по префиксу")
        #expect(KnowledgeRetriever.matches(key: "кровотеч", word: "кровотечения"))
        #expect(!KnowledgeRetriever.matches(key: "жгут", word: "жгу"),
                "слово-огрызок короче 4 не матчится в обратную сторону")
    }

    /// Все четыре пака парсятся: есть ядро и оглавление.
    @Test func allPresetPacksParse() throws {
        for preset in SophiePreset.allCases {
            let base = try KnowledgeBase.load(file: preset.kbFile)
            let hasCore = base.sections.contains { $0.isCore }
            let hasTOC = base.sections.contains { $0.isTOC }
            #expect(hasCore, "\(preset.kbFile): нет ядра")
            #expect(hasTOC, "\(preset.kbFile): нет оглавления")
            #expect(base.sections.count >= 4, "\(preset.kbFile): подозрительно мало секций")
        }
    }

    /// Маршрутизация: свободный чат ищет по ВСЕМ базам, пресет — только
    /// по своей. Запрос цепляет и первую помощь, и связь.
    @Test func freeChatSearchesAllBasesPresetOnlyOwn() throws {
        let query = "кровь не останавливается и сигнал слабый не ловит"
        let allBases = try SophiePreset.allCases.map {
            try KnowledgeBase.load(file: $0.kbFile)
        }

        // Свободный чат: секции из РАЗНЫХ баз в одном блоке
        let freeBlock = try #require(
            SophieKnowledge.blockForFreeChat(query: query, bases: allBases))
        #expect(freeBlock.contains("Сильное кровотечение"), "секция первой помощи")
        #expect(freeBlock.contains("Как улучшить сигнал"), "секция связи")
        #expect(freeBlock.contains(SophieKnowledge.freeChatBlockHeader))
        #expect(!freeBlock.contains("Отвечай ТОЛЬКО по ним"),
                "свободному чату база — источник, а не клетка")

        // Пресет «Связь»: только своя база, чужих секций нет
        let commsBase = try KnowledgeBase.load(file: SophiePreset.comms.kbFile)
        let commsBlock = SophieKnowledge.blockForPreset(.comms, query: query,
                                                      base: commsBase)
        #expect(commsBlock.contains("Как улучшить сигнал"))
        #expect(!commsBlock.contains("Сильное кровотечение"),
                "пресет не должен тянуть чужую базу")
        #expect(commsBlock.contains("Отвечай ТОЛЬКО по ним"), "блок спеки — в пресете")

        // Свободный чат без совпадений — без блока знаний вообще
        #expect(SophieKnowledge.blockForFreeChat(query: "какая завтра погода",
                                               bases: allBases) == nil)
    }

    /// Кросс-базовая выборка держит общий бюджет.
    @Test func crossBaseBudget() throws {
        let allBases = try SophiePreset.allCases.map {
            try KnowledgeBase.load(file: $0.kbFile)
        }
        let sections = KnowledgeRetriever.selectAcross(
            allBases,
            query: "кровь перелом ожог сигнал узлы sos батарея модель настройки статус")
        let total = sections.reduce(0) { $0 + KnowledgeRetriever.estimatedTokens($1.body) }
        #expect(total <= KnowledgeRetriever.tokenBudget)
        #expect(sections.count > 2)
    }

    /// Промпт пресет-чата: блок из спеки + выдержки + новое сообщение;
    /// для «Первой помощи» — строка предосторожности.
    @Test func presetPromptAssembly() throws {
        let base = try KnowledgeBase.load(file: SophiePreset.firstAid.kbFile)
        let query = "у друга кровь не останавливается"
        let excerpts = KnowledgeRetriever.excerpt(from: base, query: query)
        let block = SophiePreset.firstAid.promptBlock + "\n\n" + excerpts
        let prompt = SophiePrompt.userPrompt(window: [], newText: query,
                                           knowledgeBlock: block)

        #expect(prompt.contains("Отвечай ТОЛЬКО по ним"), "блок из kb_spec — дословно")
        #expect(prompt.contains("не замена медицинской помощи"),
                "у Первой помощи — доп. строка предосторожности")
        #expect(prompt.contains("Сильное кровотечение"), "выдержки в промпте")
        #expect(prompt.hasSuffix("Пользователь: " + query),
                "новое сообщение — последней строкой")
        // Блок знаний после истории — до нового сообщения
        let blockRange = prompt.range(of: "Отвечай ТОЛЬКО")!
        let queryRange = prompt.range(of: "Пользователь: " + query)!
        #expect(blockRange.lowerBound < queryRange.lowerBound)
    }
}
