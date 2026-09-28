import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Пак «История названия» (бриф 02.08): приёмка ретривера, красная
// фикстура «шапки», гейт слабой выдачи. Всё детерминированно, без LLM.
// ============================================================================

nonisolated struct HistoryPackTests {

    private func base() throws -> KnowledgeBase {
        try KnowledgeBase.load(file: "kb_history_ru")
    }

    // MARK: П.4 — приоритетная секция находится по целевым запросам

    @Test("«почему приложение называется Шаппи» находит секцию названий")
    func priorityQueriesHitNamingSection() throws {
        let kb = try base()
        for query in ["почему приложение называется шаппи",
                      "в честь кого назван ассистент",
                      "кто такая софи",
                      "откуда название Шаппе"] {
            let picked = KnowledgeRetriever.excerpt(from: kb, query: query)
            #expect(picked.contains("Происхождение названий"),
                    "запрос «\(query)» не нашёл секцию: \(picked.prefix(120))")
        }
    }

    @Test("правила изложения включаются всегда (секция-ядро)")
    func rulesAreAlwaysIncluded() throws {
        let kb = try base()
        for query in ["когда родился клод", "какая фраза 1791",
                      "совершенно посторонний запрос"] {
            let picked = KnowledgeRetriever.excerpt(from: kb, query: query)
            #expect(picked.contains("Правила изложения"),
                    "ядро пропало на «\(query)»")
            // критичные запреты — в ядре дословно по смыслу
            #expect(picked.contains("НЕ приписывать Софи"))
            #expect(picked.contains("первой телеграммой"))
            #expect(picked.contains("самоубийств"))
        }
    }

    // MARK: П.3 — осторожные формулировки не превратились в утверждения

    @Test("вероятные сведения остались вероятными")
    func uncertainFactsStayUncertain() throws {
        let kb = try base()
        let sophie = kb.sections.first { $0.title.contains("Софи-Франсуаза") }
        let body = try #require(sophie?.body)
        #expect(body.contains("вероятно 1837"))
        #expect(body.contains("не просмотрен"))
        let family = kb.sections.first { $0.title.contains("Родители") }
        #expect(try #require(family?.body).contains("1783 или 1784"))
    }

    @Test("URL в секциях отсутствуют, источники — только ID")
    func noURLsInsideSections() throws {
        let kb = try base()
        for section in kb.sections {
            #expect(!section.body.contains("http"),
                    "URL в секции «\(section.title)»")
        }
        #expect(kb.sections.contains { $0.body.contains("CHAPPE-S1") })
    }

    // MARK: П.6 — красная фикстура «шапки» (реальный инцидент)

    @Test("красная фикстура: ответ про «старинные шапки» невозможен из базы")
    func redFixtureShapkiIncident() throws {
        // Инцидент: на «почему приложение называется Шаппи» модель
        // ответила про «старинные шапки — тёплые и устойчивые к сбоям»,
        // добавив, что в базе объяснения нет. Это отказ контракта
        // честности. Фикстура: теперь база ОБЯЗАНА давать секцию, где
        // связь с шапками явно ОТРИЦАЕТСЯ.
        let kb = try base()
        let picked = KnowledgeRetriever.excerpt(
            from: kb, query: "почему приложение называется шаппи")
        #expect(picked.contains("не имеет отношения к головным уборам")
                || picked.contains("не связано ни с каким русским словом"),
                "секция обязана явно отрицать «шапочную» этимологию")
        #expect(picked.contains("в честь Клода Шаппа"))
        // и слово «шапка» в ядре-правилах — как запрещённый миф
        #expect(picked.contains("шапка") || picked.contains("Шапка")
                || picked.contains("«шапк"))
    }

    @Test("копия пака в бандле совпадает с каноническим файлом")
    func bundleCopyMatchesCanonical() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let canonical = try Data(contentsOf: root
            .appendingPathComponent("packs/history_chappe_v0.md"))
        let bundled = try #require(Bundle(for: BundleToken.self)
            .url(forResource: "kb_history_ru", withExtension: "md",
                 subdirectory: "sophie_kb")
            ?? Bundle.main.url(forResource: "kb_history_ru",
                               withExtension: "md"))
        #expect(try Data(contentsOf: bundled) == canonical,
                "копия в бандле разъехалась с packs/")
    }
}

private final class BundleToken {}

// MARK: - П.7: гейт слабой выдачи — демонстрация, что его НЕТ

nonisolated struct WeakRetrievalGateTests {

    @Test("ретривер honest: вне тем всех баз блок знаний = nil")
    func offTopicYieldsNilBlock() throws {
        let bases = SophiePreset.allCases.compactMap {
            try? KnowledgeBase.load(file: $0.kbFile)
        }
        #expect(bases.count == SophiePreset.allCases.count)
        let block = SophieKnowledge.blockForFreeChat(
            query: "как испечь шарлотку с корицей", bases: bases)
        #expect(block == nil, "посторонний запрос не должен находить секций")
    }

    @Test("гейт слабой выдачи ОТСУТСТВУЕТ — фиксация дефекта, не нормы")
    func weakGateIsAbsentToday() throws {
        // Почему инцидент «шапки» был возможен: при nil-блоке свободный
        // чат НЕ добавляет в промпт ни знаний, ни принуждения к отказу —
        // модель отвечает из весов. Программной ветки «в моих паках
        // этого нет» в SophieChatModel нет (проверено по коду 02.08:
        // knowledgeBlock == nil → промпт уходит без ограничителя).
        // Это ТРЕТИЙ подтверждённый случай правила «правила в промпте
        // не работают» — гейт должен стать кодом. Здесь фиксируем
        // текущее поведение, чинить — отдельное решение владельца.
        let bases = SophiePreset.allCases.compactMap {
            try? KnowledgeBase.load(file: $0.kbFile)
        }
        let block = SophieKnowledge.blockForFreeChat(
            query: "как испечь шарлотку с корицей", bases: bases)
        // Сегодняшний контракт: nil — и ничего больше. Когда гейт
        // появится, этот тест обязан упасть и быть переписанным на
        // проверку честного отказа.
        #expect(block == nil)
    }
}
