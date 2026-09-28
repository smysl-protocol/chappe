import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Гейт извлечения памяти (шаг 3.2). Требование владельца 21.08: смысл
// гейта — НИЗКАЯ частота эскалаций в модель, поэтому замки считают
// вызовы провайдера (0 на эвристиках) и счётчики трейса.
// ScriptedProvider — из SophieLoopTests (общий тест-таргет).
// ============================================================================

struct SophieRetrievalGateTests {

    private func makeGate(script: [String])
    throws -> (SophieRetrievalGate, ScriptedProvider, SophieTrace) {
        let provider = ScriptedProvider(script: script)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sophie_gate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let trace = SophieTrace(root: root)
        let gate = SophieRetrievalGate(
            scheduler: ModelScheduler(makeProvider: { provider }),
            trace: trace)
        return (gate, provider, trace)
    }

    @Test("пустая память: не искать и модель не звать")
    func emptyMemorySkipsRetrieval() async throws {
        let (gate, provider, _) = try makeGate(script: [])
        let decision = await gate.decide(for: "помнишь, что я говорил?",
                                         memoryIsEmpty: true)
        #expect(!decision.retrieve, "в пустой памяти искать нечего")
        #expect(decision.route == .heuristic)
        #expect(await provider.calls == 0, "самая дешёвая эвристика — первая")
    }

    @Test("приветствие: эвристика отвечает «нет» без модели")
    func greetingSkipsWithoutModel() async throws {
        let (gate, provider, _) = try makeGate(script: [])
        for text in ["привет", "Добрый день", "спасибо!"] {
            let decision = await gate.decide(for: text, memoryIsEmpty: false)
            #expect(!decision.retrieve, "«\(text)» — светская беседа")
            #expect(decision.route == .heuristic)
        }
        #expect(await provider.calls == 0)
    }

    @Test("маркер памяти: эвристика отвечает «да» без модели")
    func memoryMarkerRetrievesWithoutModel() async throws {
        let (gate, provider, _) = try makeGate(script: [])
        let text = "помнишь, что я говорил про лодку?"
        let decision = await gate.decide(for: text, memoryIsEmpty: false)
        #expect(decision.retrieve)
        #expect(decision.route == .heuristic)
        #expect(decision.query == text, "эвристика ищет по исходному тексту")
        #expect(await provider.calls == 0,
                "маркеры «помнишь/я говорил/моё» решаются кодом — батарея")
    }

    @Test("неоднозначное эскалируется в модель (≤80 токенов)")
    func ambiguousEscalatesToModel() async throws {
        let (gate, provider, _) = try makeGate(
            script: [#"{"retrieve": false, "query": ""}"#])
        let decision = await gate.decide(for: "расскажи анекдот про пингвина",
                                         memoryIsEmpty: false)
        #expect(!decision.retrieve)
        #expect(decision.route == .model, "решала модель, не эвристика")
        #expect(await provider.calls == 1)
        let prompt = try #require(await provider.prompts.first)
        let request = try #require(await provider.requests.first)
        #expect(prompt.contains("пингвина"), "модель видит сообщение")
        #expect(request.maxTokens <= 80, "гейт обязан быть дешёвым")
    }

    @Test("мусор от модели — fail-open: искать по исходному тексту")
    func modelGarbageFailsOpen() async throws {
        let (gate, provider, _) = try makeGate(
            script: ["не знаю", "всё ещё не JSON"])
        let text = "расскажи анекдот про пингвина"
        let decision = await gate.decide(for: text, memoryIsEmpty: false)
        #expect(decision.retrieve, Comment(rawValue:
                "пропущенный факт дороже лишнего поиска (вчетверо, "
                + "cost-weighted шага 4) — сбой гейта открывает память"))
        #expect(decision.query == text)
        #expect(decision.route == .model)
    }

    @Test("счётчики трейса: эвристики и эскалации считаются врозь")
    func traceCountsRoutes() async throws {
        let (gate, _, trace) = try makeGate(
            script: [#"{"retrieve": true, "query": "пингвин"}"#])
        _ = await gate.decide(for: "привет", memoryIsEmpty: false)
        _ = await gate.decide(for: "помнишь моё имя?", memoryIsEmpty: false)
        _ = await gate.decide(for: "расскажи анекдот про пингвина",
                              memoryIsEmpty: false)
        let counters = await trace.counters()
        #expect(counters.gateHeuristic == 2)
        #expect(counters.gateModel == 1)
    }
}

// ============================================================================
// Интеграция: блок памяти доезжает до промпта финального вызова.
// ============================================================================

@MainActor
struct SophieMemoryPromptTests {

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("свободный чат: найденный факт попадает в промпт ответа")
    func memoryBlockReachesFinalPrompt() async throws {
        // Память с фактом — в temp-мире
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sophie_mem_prompt_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let memory = SophieMemoryStore(
            fileURL: dir.appendingPathComponent("memory.enc"),
            key: SymmetricKey(size: .bits256))
        await memory.addFact(subject: "пользователь",
                             content: "живёт на Бали, в Убуде",
                             source: "manual")

        // Свободный чат: маркер «помнишь» → гейт эвристикой, без модели;
        // скрипт: выбор инструмента (none) + финальный ответ
        let provider = ScriptedProvider(
            script: [#"{"tool":"none"}"#, "Конечно, помню."])
        let chat = SophieChatInfo(id: "user_TEST_MEMORY", title: "тест",
                                  createdAt: Date())
        let model = SophieChatModel(preset: nil, chat: chat)
        model.scheduler = ModelScheduler(makeProvider: { provider })
        model.memory = memory
        defer { SophieChatStore.deleteChat(key: "user_TEST_MEMORY") }

        // Запрос делит с фактом токен «Бали»: поиск v1 точнотокенный
        // (морфология живу/живёт — известное ограничение, см. отчёт)
        model.input = "помнишь, что я говорил про Бали?"
        model.send()
        await waitUntil { !model.isGenerating && model.messages.count == 2 }

        let finalPrompt = try #require(await provider.prompts.last)
        #expect(finalPrompt.contains("живёт на Бали"), Comment(rawValue:
                "гейт открыл память, поиск нашёл факт — блок памяти обязан "
                + "стоять в промпте финального вызова"))
        #expect(await provider.calls == 2, Comment(rawValue:
                "гейт по маркеру решён эвристикой — модель звалась дважды "
                + "(выбор инструмента + ответ), не трижды"))
    }
}
