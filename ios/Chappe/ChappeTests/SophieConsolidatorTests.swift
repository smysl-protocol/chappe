import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Консолидация памяти (шаг 3.3). Мир теста: temp-стор памяти +
// тест-ключ чата в реальном SophieChatStore (паттерн SophieSummarizerTests),
// ScriptedProvider из SophieLoopTests. Ожидания извне: порог 12
// сообщений, потолки 5 фактов / 200 символов — из спеки шага 3.
// ============================================================================

struct SophieConsolidatorTests {

    private func makeMemory() throws -> SophieMemoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sophie_consol_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return SophieMemoryStore(
            fileURL: dir.appendingPathComponent("memory.enc"),
            key: SymmetricKey(size: .bits256))
    }

    private func makeConsolidator(script: [String])
    -> (SophieConsolidator, ScriptedProvider) {
        let provider = ScriptedProvider(script: script)
        let consolidator = SophieConsolidator(
            scheduler: ModelScheduler(makeProvider: { provider }),
            powerPolicy: { true },
            trace: SophieTrace(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("consol_trace_\(UUID().uuidString)")))
        return (consolidator, provider)
    }

    /// n сообщений «Пользователь/Софи» в реальный стор под тест-ключом.
    private func seedChat(_ n: Int) -> String {
        let key = "consol_test_\(UUID().uuidString)"
        let messages = (0..<n).map { i in
            SophieMessage(role: i.isMultiple(of: 2) ? .user : .sophie,
                          text: "реплика номер \(i), немного про Бали")
        }
        SophieChatStore.save(messages, key: key)
        return key
    }

    private static let goodJSON = """
    {"facts": [{"subject": "пользователь", "content": "живёт на Бали"}], \
    "episode": "Обсуждали жизнь на Бали."}
    """

    @Test("порог достигнут: факты и эпизод в памяти, курсор сдвинут, повтор — тишина")
    func consolidatesOnceAfterThreshold() async throws {
        let memory = try makeMemory()
        let (consolidator, provider) = makeConsolidator(
            script: [Self.goodJSON])
        let key = seedChat(SophieConsolidator.everyMessages)
        defer { SophieChatStore.deleteChat(key: key) }

        await consolidator.runIfNeeded(key: key, memory: memory)

        let facts = await memory.facts()
        #expect(facts.map(\.content) == ["живёт на Бали"])
        #expect(facts.first?.source == "consolidation")
        let episodes = await memory.episodes()
        #expect(episodes.map(\.summary) == ["Обсуждали жизнь на Бали."])
        #expect(await memory.consolidationCursor(for: key)
                == SophieConsolidator.everyMessages, "курсор сдвинут")

        // Идемпотентность: без новых сообщений модель не зовётся
        await consolidator.runIfNeeded(key: key, memory: memory)
        #expect(await provider.calls == 1, Comment(rawValue:
                "повторный вызов без новых сообщений обязан быть тишиной — "
                + "иначе консолидация жуёт одно и то же (батарея)"))
    }

    @Test("ниже порога — модель не зовётся вовсе")
    func belowThresholdIsSilent() async throws {
        let memory = try makeMemory()
        let (consolidator, provider) = makeConsolidator(script: [])
        let key = seedChat(SophieConsolidator.everyMessages - 1)
        defer { SophieChatStore.deleteChat(key: key) }

        await consolidator.runIfNeeded(key: key, memory: memory)
        #expect(await provider.calls == 0)
        #expect(await memory.facts().isEmpty)
    }

    @Test("мусор от модели: курсор цел, следующий повод пробует снова")
    func garbageKeepsCursorForRetry() async throws {
        let memory = try makeMemory()
        let (consolidator, provider) = makeConsolidator(
            script: ["не осилила", "и снова мимо", Self.goodJSON])
        let key = seedChat(SophieConsolidator.everyMessages)
        defer { SophieChatStore.deleteChat(key: key) }

        await consolidator.runIfNeeded(key: key, memory: memory)
        #expect(await memory.facts().isEmpty, "мусор в память не попал")
        #expect(await memory.consolidationCursor(for: key) == 0, Comment(
                rawValue: "сбой не двигает курсор — необработанное не "
                + "теряется (идемпотентность waku)"))

        // Следующий повод: та же история, третья заготовка — валидная
        await consolidator.runIfNeeded(key: key, memory: memory)
        #expect(await memory.facts().map(\.content) == ["живёт на Бали"])
        #expect(await provider.calls == 3, "2 попытки сбоя + 1 успешная")
    }

    @Test("потолок фактов за раунд держит код")
    func factsCappedPerRound() async throws {
        let memory = try makeMemory()
        let overflow = (0..<8).map {
            #"{"subject": "s", "content": "факт \#($0)"}"#
        }.joined(separator: ", ")
        let (consolidator, _) = makeConsolidator(
            script: [#"{"facts": [\#(overflow)], "episode": "э."}"#])
        let key = seedChat(SophieConsolidator.everyMessages)
        defer { SophieChatStore.deleteChat(key: key) }

        await consolidator.runIfNeeded(key: key, memory: memory)
        #expect(await memory.facts().count
                == SophieConsolidator.maxFactsPerRound, Comment(rawValue:
                "маленькие модели множат пункты — потолок за раунд "
                + "обязан держать КОД, схема без грамматики не гарантия"))
    }

    @Test("точный дубль факта не плодится")
    func duplicateFactSkipped() async throws {
        let memory = try makeMemory()
        await memory.addFact(subject: "пользователь",
                             content: "живёт на Бали", source: "manual")
        let (consolidator, _) = makeConsolidator(script: ["""
        {"facts": [{"subject": "пользователь", "content": "живёт на Бали"}, \
        {"subject": "пользователь", "content": "любит кофе"}], \
        "episode": "э."}
        """])
        let key = seedChat(SophieConsolidator.everyMessages)
        defer { SophieChatStore.deleteChat(key: key) }

        await consolidator.runIfNeeded(key: key, memory: memory)
        let contents = await memory.facts().map(\.content)
        #expect(contents == ["живёт на Бали", "любит кофе"],
                "дубль пропущен, новое добавлено: \(contents)")
    }

    @Test("длину эпизода считает код, не модель")
    func episodeClampedByCode() async throws {
        let memory = try makeMemory()
        let longTale = String(repeating: "ба", count: 300)
        let (consolidator, _) = makeConsolidator(
            script: [#"{"facts": [], "episode": "\#(longTale)"}"#])
        let key = seedChat(SophieConsolidator.everyMessages)
        defer { SophieChatStore.deleteChat(key: key) }

        await consolidator.runIfNeeded(key: key, memory: memory)
        let episode = try #require(await memory.episodes().first)
        #expect(episode.summary.count <= SophieConsolidator.maxEpisodeChars,
                Comment(rawValue: "потолок \(SophieConsolidator.maxEpisodeChars), "
                + "вышло \(episode.summary.count)"))
    }

    @Test("без питания консолидация не запускается")
    func powerPolicyBlocks() async throws {
        let memory = try makeMemory()
        let provider = ScriptedProvider(script: [Self.goodJSON])
        let consolidator = SophieConsolidator(
            scheduler: ModelScheduler(makeProvider: { provider }),
            powerPolicy: { false },
            trace: SophieTrace(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("consol_pw_\(UUID().uuidString)")))
        let key = seedChat(SophieConsolidator.everyMessages)
        defer { SophieChatStore.deleteChat(key: key) }

        await consolidator.runIfNeeded(key: key, memory: memory)
        #expect(await provider.calls == 0,
                "P3 бережёт батарею — как у суммаризатора")
    }
}

// ============================================================================
// Модель экрана «Что помнит Софи»: зеркало читает и удаляет навсегда.
// ============================================================================

@MainActor
struct SophieMemoryModelTests {

    @Test("зеркало показывает память и удаляет навсегда")
    func mirrorLoadsAndDeletes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sophie_mirror_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let store = SophieMemoryStore(
            fileURL: dir.appendingPathComponent("memory.enc"),
            key: SymmetricKey(size: .bits256))
        await store.addFact(subject: "пользователь",
                            content: "живёт на Бали", source: "manual")
        await store.addEpisode(happenedAt: Date(), summary: "эпизод")

        let model = SophieMemoryModel()
        model.memory = store
        await model.load()
        #expect(model.facts.map(\.content) == ["живёт на Бали"])
        #expect(model.episodes.map(\.summary) == ["эпизод"])

        let factID = try #require(model.facts.first?.id)
        await model.deleteFact(factID)
        #expect(model.facts.isEmpty, "зеркало обновилось")
        #expect(await store.facts().isEmpty, "удаление дошло до стора")
    }
}
