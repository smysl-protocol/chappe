import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Фаза 3: фоновая суммаризация (первая настоящая P3-задача).
// Триггер >1500 токенов за окном, чанки, курсор, вытеснение P0–P2,
// возобновление с курсора, суммарий в промпте, лимит слов кодом.
// ============================================================================

/// Провайдер для свёртки: отдаёт помеченный суммарий мгновенно; по
/// желанию первые N вызовов «долгие» (вытесняемые cancelActiveGeneration).
actor SummaryMockProvider {
    nonisolated let kind: LLMProviderKind = .local
    nonisolated let capabilities: LLMCapabilities = [.cancellation]
    private(set) var isLoaded = false
    private nonisolated let cancelFlag = AtomicFlag()
    private(set) var calls = 0
    let slowTicksFirstCall: Int

    init(slowTicksFirstCall: Int = 0) {
        self.slowTicksFirstCall = slowTicksFirstCall
    }

    func load(_ config: LLMModelConfig) async throws { isLoaded = true }
    func unload() async { isLoaded = false }

    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        cancelFlag.clear()
        calls += 1
        if calls == 1, slowTicksFirstCall > 0 {
            for _ in 0..<slowTicksFirstCall {
                if cancelFlag.isSet { throw LLMError.cancelled }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return LLMResponse(text: "суммарий v\(calls)", tokensGenerated: 1,
                           tokensPerSecond: 0, finishReason: .stop)
    }

    func generateStructured(_ request: LLMRequest,
                            spec: StructuredSpec) async throws -> LLMResponse {
        throw LLMError.structuredOutputUnsupported
    }

    nonisolated func cancelActiveGeneration() { cancelFlag.set() }
}

nonisolated struct SophieSummarizerTests {

    /// Длинная история: суммарно ~5300 оценочных токенов —
    /// за окном (3000) остаётся заметно больше порога 1500.
    private func makeHistory(count: Int = 40) -> [SophieMessage] {
        (0..<count).map { i in
            SophieMessage(role: i.isMultiple(of: 2) ? .user : .sophie,
                        text: "Сообщение номер \(i): "
                        + String(repeating: "слово ", count: 65))
        }
    }

    private func withChat(_ messages: [SophieMessage],
                          _ body: (String) async throws -> Void)
    async rethrows {
        let key = "test_sum_" + UUID().uuidString.prefix(8)
        SophieChatStore.save(messages, key: String(key))
        defer { SophieChatStore.deleteChat(key: String(key)) }
        try await body(String(key))
    }

    @Test("Свёртка чанками до начала окна, курсор двигается")
    func summarizesInChunksUpToWindow() async throws {
        let provider = SummaryMockProvider()
        let scheduler = ModelScheduler(makeProvider: { provider })
        let summarizer = SophieSummarizer(scheduler: scheduler,
                                        powerPolicy: { true })
        let history = makeHistory()
        await withChat(history) { key in
            await summarizer.runIfNeeded(key: key)
            let state = SophieChatStore.loadSummary(key: key)
            #expect(state.text.hasPrefix("суммарий"), "\(state)")
            #expect(state.cursor > 0)
            // свёрнуто ровно до начала окна — дыры нет
            let unsummarized = Array(history[state.cursor...])
            let window = SophiePrompt.window(unsummarized)
            #expect(unsummarized.count == window.count,
                    "за окном не должно остаться несвёрнутого")
            let calls = await provider.calls
            #expect(calls >= 2, "ожидались чанки: \(calls) вызов(а)")
        }
    }

    @Test("Ниже порога 1500 — модель не дёргаем")
    func belowThresholdDoesNothing() async throws {
        let provider = SummaryMockProvider()
        let scheduler = ModelScheduler(makeProvider: { provider })
        let summarizer = SophieSummarizer(scheduler: scheduler,
                                        powerPolicy: { true })
        await withChat(makeHistory(count: 6)) { key in
            await summarizer.runIfNeeded(key: key)
            #expect(SophieChatStore.loadSummary(key: key) == .init())
            let calls = await provider.calls
            #expect(calls == 0)
        }
    }

    @Test("Политика питания закрыта — свёртка не запускается")
    func powerPolicyBlocks() async throws {
        let provider = SummaryMockProvider()
        let scheduler = ModelScheduler(makeProvider: { provider })
        let summarizer = SophieSummarizer(scheduler: scheduler,
                                        powerPolicy: { false })
        await withChat(makeHistory()) { key in
            await summarizer.runIfNeeded(key: key)
            let calls = await provider.calls
            #expect(calls == 0)
        }
    }

    @Test("Вытеснение P0 обрывает свёртку; возобновление с курсора")
    func preemptionThenResumeFromCursor() async throws {
        // Первый вызов свёртки «долгий» — успеем вытеснить его P0
        let provider = SummaryMockProvider(slowTicksFirstCall: 400)
        let scheduler = ModelScheduler(makeProvider: { provider })
        let summarizer = SophieSummarizer(scheduler: scheduler,
                                        powerPolicy: { true })
        await withChat(makeHistory()) { key in
            let background = Task { await summarizer.runIfNeeded(key: key) }
            try? await Task.sleep(nanoseconds: 200_000_000)   // P3 стартовал

            // P0 прилетает — P3 обязан отмениться мгновенно
            let sos = try? await scheduler.withProvider(.sos) { p in
                try await p.generate(LLMRequest(prompt: "sos", maxTokens: 1))
            }
            #expect(sos != nil)
            await background.value

            // Свёртка оборвалась до записи — курсор цел (0), не мусор
            let afterPreempt = SophieChatStore.loadSummary(key: key)
            #expect(afterPreempt.cursor == 0)

            // Возобновление: второй заход доводит до начала окна
            await summarizer.runIfNeeded(key: key)
            let final = SophieChatStore.loadSummary(key: key)
            #expect(final.cursor > 0)
            let messages = SophieChatStore.load(key: key)
            let window = SophiePrompt.window(Array(messages[final.cursor...]))
            #expect(messages.count - final.cursor == window.count)
        }
    }

    @Test("Суммарий попадает в промпт первым блоком")
    func summaryLandsInPrompt() {
        let window = [SophieMessage(role: .user, text: "как дела")]
        let prompt = SophiePrompt.userPrompt(window: window,
                                           newText: "что решили?",
                                           summary: "договорились выйти в 6")
        #expect(prompt.hasPrefix("Суммарий более раннего разговора"))
        #expect(prompt.contains("договорились выйти в 6"))
        #expect(prompt.contains("Пользователь: как дела"))
        // без суммария блока нет
        let plain = SophiePrompt.userPrompt(window: window, newText: "привет")
        #expect(!plain.contains("Суммарий"))
    }

    @Test("Лимит 120 слов держит код, не модель")
    func wordLimitEnforcedByCode() {
        let long = (0..<200).map { "слово\($0)" }.joined(separator: " ")
        let clamped = SophieSummarizer.clampWords(long)
        let words = clamped.split(whereSeparator: { $0.isWhitespace })
        #expect(words.count == SophieSummarizer.maxWords)
        #expect(clamped.hasSuffix("…"))
        let short = "короткий суммарий"
        #expect(SophieSummarizer.clampWords(short) == short)
    }
}

extension SummaryMockProvider: LLMProvider {}
