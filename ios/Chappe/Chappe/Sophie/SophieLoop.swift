import Foundation

// ============================================================================
// SophieLoop — маленький легибл-цикл Софи (линия Софи, шаг 2; по мотивам
// цикла waku-agent, адаптирован под 4B на телефоне).
//
// Ход = раунды инструментов (потолок maxToolRounds) + финальный ответ.
// В терминах постановки maxIterations = maxToolRounds + 1 финальный
// вызов; сейчас потолок 1 → максимум 2 вызова модели за ход (решение
// владельца 21.08; пересматривать по мере роста инструментов — эвал
// обязан ловить «нужен ещё раунд, потолок обрезал»).
//
// Маршрутизация детерминированная: модель только ВЫБИРАЕТ инструмент,
// исполняет КОД (правило №9). Модель без нативного tool-calling
// (ModelBackendProfile) идёт текстовым протоколом через StructuredLLM —
// это деградация по возможностям, не единственный путь. Сбой выбора не
// роняет ход: fail-open в обычный ответ. Каждый вызов и инструмент —
// событием в SophieTrace.
// ============================================================================

nonisolated struct SophieLoop: Sendable {

    var scheduler: ModelScheduler = .shared
    var trace: SophieTrace = .shared
    /// Потолок раундов инструментов до финального ответа.
    var maxToolRounds = 1

    /// Раунды инструментов (вызов №1..N): выбор моделью, исполнение кодом.
    /// nil — инструмент не нужен или выбор не удался (обычный ответ);
    /// без установленной модели — честный unavailable-блок.
    func toolRounds(for text: String) async -> String? {
        await toolRoundsCounted(for: text).block
    }

    /// То же + число логических обращений к модели (для turn_end;
    /// repair-попытки внутри StructuredLLM отдельно не считаются).
    func toolRoundsCounted(for text: String)
    async -> (block: String?, llmCalls: Int) {
        // Без модели выбор и формулировка невозможны — честный текст
        // вместо молчания (п.6 плана 29.07); карта и газетир живут и так
        guard ModelScheduler.isLocalProviderActive() else {
            return (SophieTools.answerBlock(for: .init(
                summary: SophieTools.assistantUnavailableSummary)), 0)
        }
        var block: String?
        var llmCalls = 0
        for _ in 0..<max(1, maxToolRounds) {
            let call: SophieToolCall
            llmCalls += 1
            do {
                let request = LLMRequest(
                    prompt: SophieTools.selectionPrompt(for: text),
                    maxTokens: 80,
                    samplingOverride: .extraction)
                let extracted = try await scheduler.withProvider(.interactive) { provider in
                    try await StructuredLLM.callRaw(
                        provider: provider,
                        request: request,
                        spec: SophieTools.selectionSpec,
                        as: SophieToolCall.self,
                        validate: SophieTools.validate(_:))
                }
                await trace.note(.llm(kind: .select, tokens: nil,
                                      tokensPerSecond: extracted.tokensPerSecond,
                                      finish: nil))
                call = extracted.value
            } catch {
                // Fail-open: сбой выбора не роняет ход — отвечаем без блока
                await trace.note(.error(domain: .toolSelect))
                return (block, llmCalls)
            }
            guard call.tool != .none else { return (block, llmCalls) }
            let result = await Self.execute(call)
            await trace.note(.tool(call.tool, ok: true))
            block = SophieTools.answerBlock(for: result)
            // v1: результат инструмента не рождает нового выбора —
            // несколько раундов появятся вместе с цепочками инструментов
            break
        }
        return (block, llmCalls)
    }

    /// Финальный ответ (последний вызов хода): стриминг, метрики в трейс.
    func finalAnswer(_ request: LLMRequest,
                     priority: LLMPriority = .interactive,
                     onToken: @escaping @Sendable (String) -> Void)
    async throws -> LLMResponse {
        do {
            let response = try await scheduler.withProvider(priority) { provider in
                try await provider.generateStreaming(request, onToken: onToken)
            }
            await trace.note(.llm(kind: .answer,
                                  tokens: response.tokensGenerated,
                                  tokensPerSecond: response.tokensPerSecond,
                                  finish: response.finishReason))
            return response
        } catch {
            if case LLMError.cancelled = error {
                await trace.note(.error(domain: .cancelled))
            } else {
                await trace.note(.error(domain: .llm))
            }
            throw error
        }
    }

    /// Исполнение выбранного инструмента — всегда КОД, никогда модель.
    static func execute(_ call: SophieToolCall) async -> SophieTools.ToolResult {
        switch call.tool {
        case .none:
            return .init(summary: "")   // недостижимо: none отсеян раньше
        case .deviceStatus:
            return await SophieTools.runDeviceStatus()
        case .myLocation:
            return await SophieTools.runMyLocation()
        case .distanceEta:
            return await SophieTools.runDistanceEta(call)
        case .peerPosition:
            return await SophieTools.runPeerPosition(call)
        case .tileCoverage:
            return await SophieTools.runTileCoverage(call)
        case .weather:
            return await SophieTools.runWeather(call)
        }
    }
}
