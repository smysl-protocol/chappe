import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Пак «О проекте» (бриф 06.08): приёмка ретривера, честность о планах,
// раздел «когда выйдет / сколько стоит / инвестиции». Всё детерминированно,
// без LLM (образец — HistoryPackTests).
// ============================================================================

nonisolated struct ProjectPackTests {

    private func base() throws -> KnowledgeBase {
        try KnowledgeBase.load(file: "kb_project_ru")
    }

    // MARK: приоритетная секция находится по целевым запросам (манифест)

    @Test("«когда выйдет / сколько стоит / инвестировать» находят секцию сроков")
    func priorityQueriesHitTimelineSection() throws {
        let kb = try base()
        for query in ["когда выйдет устройство",
                      "сколько будет стоить",
                      "можно ли инвестировать",
                      "когда релиз в аппсторе",
                      "есть ли у проекта токен"] {
            let picked = KnowledgeRetriever.excerpt(from: kb, query: query)
            #expect(picked.contains("Когда выйдет, сколько стоит"),
                    "запрос «\(query)» не нашёл секцию: \(picked.prefix(120))")
        }
    }

    @Test("правила изложения включаются всегда (секция-ядро)")
    func rulesAreAlwaysIncluded() throws {
        let kb = try base()
        for query in ["как устроено сжатие", "что видит сервер",
                      "совершенно посторонний запрос"] {
            let picked = KnowledgeRetriever.excerpt(from: kb, query: query)
            #expect(picked.contains("Правила изложения о проекте"),
                    "ядро пропало на «\(query)»")
            // критичные запреты — в ядре дословно по смыслу
            #expect(picked.contains("Никаких сроков и дат"))
            #expect(picked.contains("не собирает инвестиций"))
            #expect(picked.contains("не проходил независимого аудита"))
        }
    }

    // MARK: планы поданы как планы, не как факты

    @Test("секции планов явно называют себя планами")
    func plansStayPlans() throws {
        let kb = try base()
        let device = try #require(kb.sections.first {
            $0.title.contains("собственные устройства") })
        #expect(device.body.contains("план, не обещание"))
        #expect(device.body.contains("не определены"))
        let oss = try #require(kb.sections.first {
            $0.title.contains("открытый код") })
        #expect(oss.body.contains("Даты публикации нет"))
        let community = try #require(kb.sections.first {
            $0.title.contains("сообщество") })
        #expect(community.body.contains("не решено"))
    }

    @Test("ответ о сроках: срока нет, цены нет, токена нет")
    func timelineSectionIsHonest() throws {
        let kb = try base()
        let s = try #require(kb.sections.first {
            $0.title.contains("Когда выйдет") })
        #expect(s.body.contains("срока нет"))
        #expect(s.body.contains("цены нет"))
        #expect(s.body.contains("своего токена у проекта НЕТ"))
        #expect(s.body.contains("исходит не от проекта"))
    }

    // MARK: честные границы возможностей

    @Test("кодек назван доменным честно, с текстовым запасным путём")
    func codecLimitsAreHonest() throws {
        let kb = try base()
        let s = try #require(kb.sections.first {
            $0.title.contains("Умное сжатие") })
        #expect(s.body.contains("часто не срабатывает"))
        #expect(s.body.contains("обычным текстом"))
        #expect(s.body.contains("свойство конструкции"))
    }

    @Test("приватность: сервер видит размер и время, аудита не было, Signal")
    func privacySectionMatchesThreatModel() throws {
        let kb = try base()
        let s = try #require(kb.sections.first {
            $0.title.contains("Приватность") })
        #expect(s.body.contains("размер"))
        #expect(s.body.contains("НЕ обещаем"))
        #expect(s.body.contains("Signal"))
    }

    @Test("URL в секциях отсутствуют, источники — только ID")
    func noURLsInsideSections() throws {
        let kb = try base()
        for section in kb.sections {
            #expect(!section.body.contains("http"),
                    "URL в секции «\(section.title)»")
        }
        #expect(kb.sections.contains { $0.body.contains("PROJ-S1") })
    }

    // MARK: запрещённые обещания не могут появиться незаметно

    @Test("красная фикстура: в паке нет дат выхода и цен")
    func noDatesOrPricesAnywhere() throws {
        let kb = try base()
        // Годы будущего (2026+ в контексте «выйдет в», кварталы, месяцы
        // с годом) и валюты — маркеры обещаний, которых в паке быть
        // не может. Даты документов (06.08.2026 в шапке) — вне секций.
        let promise = try NSRegularExpression(
            pattern: "к 20\\d\\d|в 20\\d\\d году|Q[1-4]\\s*20\\d\\d"
                + "|\\$\\d|\\d+\\s*(долл|руб|евро|USD|EUR)")
        for section in kb.sections {
            let hits = promise.matches(
                in: section.body, range: NSRange(
                    section.body.startIndex..., in: section.body))
            #expect(hits.isEmpty,
                    "маркер срока/цены в секции «\(section.title)»")
        }
    }

    @Test("копия пака в бандле совпадает с каноническим файлом")
    func bundleCopyMatchesCanonical() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let canonical = try Data(contentsOf: root
            .appendingPathComponent("packs/project_chappe_v0.md"))
        let bundled = try #require(Bundle(for: ProjectBundleToken.self)
            .url(forResource: "kb_project_ru", withExtension: "md",
                 subdirectory: "sophie_kb")
            ?? Bundle.main.url(forResource: "kb_project_ru",
                               withExtension: "md"))
        #expect(try Data(contentsOf: bundled) == canonical,
                "копия в бандле разъехалась с packs/")
    }

    @Test("чат «О проекте» подключён к паку")
    func presetIsWired() throws {
        #expect(SophiePreset.project.kbFile == "kb_project_ru")
        #expect(SophiePreset.project.title == "О проекте")
        let kb = try base()
        #expect(kb.name.contains("О проекте"))
    }
}

private final class ProjectBundleToken {}
