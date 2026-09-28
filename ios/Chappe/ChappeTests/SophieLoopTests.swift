import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Легибл-цикл Софи (шаг 2): раунды инструментов + финальный ответ на
// скриптованном моке (паттерн ScriptedClient из waku: очередь заготовленных
// ответов — «тест описывает свой мир», как ContinuationMockProvider).
//
// Мок НЕ умеет structured output — как боевой llama.cpp: выбор
// инструмента идёт текстовым протоколом (свободная генерация + парсинг
// + repair), это проверяемая деградация по ModelBackendProfile.
// ============================================================================

/// Очередь заготовленных ответов; считает вызовы и запоминает промпты.
actor ScriptedProvider: LLMProvider {
    nonisolated let kind: LLMProviderKind = .local
    nonisolated let capabilities: LLMCapabilities = [.cancellation]
    private(set) var isLoaded = false
    private var script: [String]
    private(set) var calls = 0
    private(set) var prompts: [String] = []
    private(set) var requests: [LLMRequest] = []

    init(script: [String]) { self.script = script }

    func load(_ config: LLMModelConfig) async throws { isLoaded = true }
    func unload() async { isLoaded = false }

    private func next(_ request: LLMRequest) -> LLMResponse {
        calls += 1
        prompts.append(request.prompt)
        requests.append(request)
        let text = script.isEmpty ? "" : script.removeFirst()
        return LLMResponse(text: text, tokensGenerated: text.count / 3,
                           tokensPerSecond: 9, finishReason: .stop)
    }

    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        next(request)
    }

    func generateStreaming(_ request: LLMRequest,
                           onToken: @escaping @Sendable (String) -> Void)
    async throws -> LLMResponse {
        let response = next(request)
        onToken(response.text)
        return response
    }

    func generateStructured(_ request: LLMRequest,
                            spec: StructuredSpec) async throws -> LLMResponse {
        throw LLMError.structuredOutputUnsupported
    }

    nonisolated func cancelActiveGeneration() {}
}

struct SophieLoopTests {

    private func makeLoop(script: [String])
    throws -> (SophieLoop, ScriptedProvider, URL) {
        let provider = ScriptedProvider(script: script)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sophie_loop_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let loop = SophieLoop(
            scheduler: ModelScheduler(makeProvider: { provider }),
            trace: SophieTrace(root: root))
        return (loop, provider, root)
    }

    private func traceText(_ root: URL) throws -> String {
        try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined()
    }

    @Test("модель выбирает инструмент — исполняет код, блок в промпт №2")
    func toolSelectionExecutesByCode() async throws {
        let (loop, provider, root) = try makeLoop(
            script: [#"{"tool":"device_status"}"#])

        let block = await loop.toolRounds(for: "сколько у нас батареи?")

        let unwrapped = try #require(block, "инструмент выбран — блок обязан быть")
        #expect(unwrapped.contains("Результат инструмента"),
                "формат блока — answerBlock, модель отвечает по данным кода")
        #expect(unwrapped.contains("батарея"),
                "device_status исполнил КОД (UIDevice), не модель")
        #expect(await provider.calls == 1, "ровно один вызов №1 — выбор")
        #expect(try traceText(root).contains(#""e":"tool""#),
                "инструмент оставил событие в трейсе")
    }

    @Test("мусор вместо JSON дважды — fail-open в обычный ответ")
    func selectionGarbageFailsOpen() async throws {
        let (loop, provider, _) = try makeLoop(
            script: ["я не знаю, что выбрать", "всё ещё не JSON"])

        let block = await loop.toolRounds(for: "как дела?")

        #expect(block == nil, "сбой выбора не роняет ход — просто без блока")
        #expect(await provider.calls == 2,
                "основная попытка + один repair (StructuredLLM)")
    }

    @Test("tool=none — инструмент не нужен, второго выбора нет")
    func toolNoneStopsRounds() async throws {
        let (loop, provider, _) = try makeLoop(script: [#"{"tool":"none"}"#])

        let block = await loop.toolRounds(for: "расскажи про звёзды")

        #expect(block == nil)
        #expect(await provider.calls == 1,
                "потолок раундов: none не порождает новых выборов")
    }

    @Test("финальный ответ стримится и оставляет метрики в трейсе")
    func finalAnswerStreamsAndTraces() async throws {
        let (loop, _, root) = try makeLoop(script: ["Птицы уже спят."])

        let response = try await loop.finalAnswer(
            LLMRequest(prompt: "Пользователь: где птицы?",
                       maxTokens: 100)) { _ in }

        #expect(response.text == "Птицы уже спят.")
        let trace = try traceText(root)
        #expect(trace.contains(#""e":"llm""#), "вызов модели виден в следе")
        #expect(trace.contains(#""kind":"answer""#),
                "финальный вызов помечен как answer")
    }

    @Test("трейс не содержит текста реплик — приватность железом")
    func traceNeverContainsUserText() async throws {
        // Конвенция Софи: содержимое чата не попадает в журнал. Замок:
        // прогнать ход с маркером и убедиться, что маркера нет ни в одном
        // файле следа. Слом: добавить текст в любое событие — красный.
        let marker = "СЕКРЕТНАЯ-РЕПЛИКА-9931"
        let (loop, _, root) = try makeLoop(
            script: [#"{"tool":"none"}"#, "Ответ без секретов."])

        _ = await loop.toolRounds(for: marker)
        _ = try await loop.finalAnswer(
            LLMRequest(prompt: "Пользователь: \(marker)",
                       maxTokens: 100)) { _ in }

        let trace = try traceText(root)
        #expect(!trace.isEmpty, "след пишется (иначе замок проверяет пустоту)")
        #expect(!trace.contains(marker), Comment(rawValue:
                "текст реплик в следе = журнал поведения с содержимым "
                + "разговоров; API трейса обязан не принимать текст"))
    }
}
