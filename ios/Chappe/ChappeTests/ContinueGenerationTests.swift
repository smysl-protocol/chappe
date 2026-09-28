import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Фаза 4: «Продолжить» после стопа. Частичный ответ уходит префиксом
// ассистента (LLMRequest.assistantPrefix), продолжение дописывается в
// тот же пузырь, маркер «остановлено» снимается при успехе.
// ============================================================================

/// Провайдер продолжения: запоминает запрос, отдаёт фиксированное
/// продолжение стримом (два чанка).
actor ContinuationMockProvider {
    nonisolated let kind: LLMProviderKind = .local
    nonisolated let capabilities: LLMCapabilities = [.cancellation]
    private(set) var isLoaded = false
    private(set) var lastRequest: LLMRequest?
    let continuation: String

    init(continuation: String) { self.continuation = continuation }

    func load(_ config: LLMModelConfig) async throws { isLoaded = true }
    func unload() async { isLoaded = false }

    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        lastRequest = request
        return LLMResponse(text: continuation, tokensGenerated: 1,
                           tokensPerSecond: 0, finishReason: .stop)
    }

    func generateStreaming(_ request: LLMRequest,
                           onToken: @escaping @Sendable (String) -> Void)
    async throws -> LLMResponse {
        lastRequest = request
        let middle = continuation.index(continuation.startIndex,
                                        offsetBy: continuation.count / 2)
        onToken(String(continuation[..<middle]))
        onToken(String(continuation[middle...]))
        return LLMResponse(text: continuation, tokensGenerated: 2,
                           tokensPerSecond: 0, finishReason: .stop)
    }

    func generateStructured(_ request: LLMRequest,
                            spec: StructuredSpec) async throws -> LLMResponse {
        throw LLMError.structuredOutputUnsupported
    }

    nonisolated func cancelActiveGeneration() {}
}

@MainActor
struct ContinueGenerationTests {

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Стоп → продолжить: связный итог, маркер снят, префикс ушёл")
    func continueAfterStop() async throws {
        let partial = " будь осторожен на воде — волны сегодня"
        let provider = ContinuationMockProvider(
            continuation: " большие, лодки лучше не брать.")
        let model = SophieChatModel(preset: .comms)
        model.scheduler = ModelScheduler(makeProvider: { provider })
        defer { SophieChatStore.save([], key: "chat_comms") }   // не сорить

        // История: вопрос + ответ, оборванный стопом
        var stoppedReply = SophieMessage(role: .sophie, text: partial)
        stoppedReply.stopped = true
        model.messages = [SophieMessage(role: .user, text: "как там море?"),
                          stoppedReply]

        model.continueGeneration(stoppedReply.id)
        await waitUntil { !model.isGenerating && model.messages.count == 2 }
        await waitUntil { model.messages.last?.isStopped == false }

        let reply = try #require(model.messages.last)
        #expect(reply.text == partial + " большие, лодки лучше не брать.",
                "итог обязан быть связным: «\(reply.text)»")
        #expect(!reply.isStopped, "маркер «остановлено» снят")

        // Частичный ответ ушёл именно префиксом ассистента
        let request = try #require(await provider.lastRequest)
        #expect(request.assistantPrefix == partial)
        // а вопрос — последней репликой пользователя в промпте
        #expect(request.prompt.hasSuffix("Пользователь: как там море?"))
    }

    @Test("Продолжить недоступно для непомеченных и во время генерации")
    func continueGuards() async throws {
        let provider = ContinuationMockProvider(continuation: "x")
        let model = SophieChatModel(preset: .comms)
        model.scheduler = ModelScheduler(makeProvider: { provider })

        let normal = SophieMessage(role: .sophie, text: "полный ответ")
        model.messages = [SophieMessage(role: .user, text: "вопрос"), normal]

        model.continueGeneration(normal.id)   // не остановлен — игнор
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.messages.last?.text == "полный ответ")
        let request = await provider.lastRequest
        #expect(request == nil, "модель не должна была дёргаться")
    }
}

extension ContinuationMockProvider: LLMProvider {}
