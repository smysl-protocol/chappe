import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Отзывчивость чата Софи (поле 22.08, скрин владельца): реплика
// «пропадала» после отправки и появлялась в ленте только через ~30 с —
// append шёл ПОСЛЕ гейта и выбора инструмента (модельные вызовы, на
// холодной модели — десятки секунд). Замок: реплика пользователя и
// пузырь ответа обязаны появиться в ленте МГНОВЕННО, до какой-либо
// работы модели.
// ============================================================================

/// Провайдер-черепаха: generate висит, пока тест проверяет ленту.
actor SlowProvider: LLMProvider {
    nonisolated let kind: LLMProviderKind = .local
    nonisolated let capabilities: LLMCapabilities = [.cancellation]
    private(set) var isLoaded = false

    func load(_ config: LLMModelConfig) async throws { isLoaded = true }
    func unload() async { isLoaded = false }

    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        return LLMResponse(text: #"{"tool":"none"}"#, tokensGenerated: 1,
                           tokensPerSecond: 0, finishReason: .stop)
    }

    func generateStreaming(_ request: LLMRequest,
                           onToken: @escaping @Sendable (String) -> Void)
    async throws -> LLMResponse {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        onToken("Ответ.")
        return LLMResponse(text: "Ответ.", tokensGenerated: 1,
                           tokensPerSecond: 0, finishReason: .stop)
    }

    func generateStructured(_ request: LLMRequest,
                            spec: StructuredSpec) async throws -> LLMResponse {
        throw LLMError.structuredOutputUnsupported
    }

    nonisolated func cancelActiveGeneration() {}
}

@MainActor
struct SophieResponsivenessTests {

    @Test("реплика и пузырь ответа в ленте мгновенно, модель — потом")
    func userMessageAppearsInstantly() async throws {
        let chat = SophieChatInfo(id: "user_TEST_INSTANT", title: "т",
                                  createdAt: Date())
        let model = SophieChatModel(preset: nil, chat: chat)
        model.scheduler = ModelScheduler(makeProvider: { SlowProvider() })
        defer { SophieChatStore.deleteChat(key: "user_TEST_INSTANT") }

        model.input = "расскажи что умеешь"
        model.send()
        // 300 мс — модель-черепаха ещё спит (3 с), лента уже обязана жить
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(model.messages.first?.text == "расскажи что умеешь",
                Comment(rawValue: "реплика обязана появиться мгновенно — "
                + "«пропавшее сообщение» читается как потеря ввода"))
        #expect(model.messages.count == 2,
                "пузырь ответа тоже сразу (индикатор ожидания)")
        #expect(model.messages.last?.role == .sophie)
        #expect(model.isGenerating, "работа модели ещё идёт")

        // Дождаться конца, чтобы не сорить в параллельные тесты
        for _ in 0..<200 where model.isGenerating {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
