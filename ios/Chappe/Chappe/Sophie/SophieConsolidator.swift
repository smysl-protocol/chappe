import Foundation

// ============================================================================
// SophieConsolidator — консолидация памяти (шаг 3.3, паттерн waku
// consolidation.py под наши ограничения): накопившиеся необработанные
// сообщения чата сворачиваются P3-вызовом в ПРОЧНЫЕ факты о
// пользователе + одно предложение-резюме эпизода.
//
// Дисциплина как у SophieSummarizer (второй настоящий P3):
// - триггер по счётчику необработанных сообщений (курсор в шифрованной
//   памяти рядом с фактами);
// - политика питания: на зарядке или батарея >30%;
// - при ЛЮБОМ сбое (мусор от модели, вытеснение, нет модели) курсор не
//   двигается — повтор при следующем поводе, идемпотентно;
// - потолки держит КОД: не больше maxFactsPerRound фактов за раунд,
//   эпизод обрезается до maxEpisodeChars (правило №4: длину считает
//   код, не модель);
// - дедуп: точный дубль subject+content не добавляется.
// ============================================================================

actor SophieConsolidator {

    static let shared = SophieConsolidator()

    /// Порог: столько необработанных сообщений копится до свёртки
    /// (12 сообщений ≈ 6 обменов, как every_n у waku).
    static let everyMessages = 12
    /// Потолок фактов за раунд — маленькие модели любят множить.
    static let maxFactsPerRound = 5
    /// Потолок длины эпизода в символах.
    static let maxEpisodeChars = 200

    private let scheduler: ModelScheduler
    private let powerPolicy: @Sendable () async -> Bool
    private let trace: SophieTrace
    private var runningKeys = Set<String>()

    /// Зависимости инжектируются в тестах; политика питания — общая с
    /// суммаризатором.
    init(scheduler: ModelScheduler = .shared,
         powerPolicy: @escaping @Sendable () async -> Bool
            = SophieSummarizer.devicePowerPolicy,
         trace: SophieTrace = .shared) {
        self.scheduler = scheduler
        self.powerPolicy = powerPolicy
        self.trace = trace
    }

    /// Свернуть необработанное чата key в память, если накопилось.
    func runIfNeeded(key: String, memory: SophieMemoryStore) async {
        guard !runningKeys.contains(key) else { return }
        runningKeys.insert(key)
        defer { runningKeys.remove(key) }

        let messages = SophieChatStore.load(key: key)
        let cursor = await memory.consolidationCursor(for: key)
        guard messages.count - cursor >= Self.everyMessages else { return }
        guard await powerPolicy() else { return }

        let chunk = Array(messages[cursor...])
        do {
            let request = LLMRequest(prompt: Self.prompt(for: chunk),
                                     maxTokens: 300,
                                     samplingOverride: .extraction)
            // P3: вытесняется любым P0–P2
            let extracted = try await scheduler.withProvider(.background) { provider in
                try await StructuredLLM.callRaw(provider: provider,
                                                request: request,
                                                spec: Self.spec,
                                                as: ConsolidationCall.self)
            }
            await trace.note(.llm(kind: .consolidate, tokens: nil,
                                  tokensPerSecond: extracted.tokensPerSecond,
                                  finish: nil))
            let call = extracted.value
            // Потолки и дедуп держит КОД: схема без грамматики — просьба
            for fact in call.facts.prefix(Self.maxFactsPerRound) {
                await memory.addFactDeduped(subject: fact.subject,
                                            content: fact.content,
                                            source: "consolidation")
            }
            let episode = Self.clampChars(call.episode)
            if !episode.isEmpty {
                await memory.addEpisode(
                    happenedAt: chunk.last?.date ?? Date(),
                    summary: episode)
            }
            // Курсор двигается ТОЛЬКО после успешной записи
            await memory.setConsolidationCursor(messages.count, for: key)
        } catch {
            // Мусор/вытеснение/нет модели: курсор цел — повтор при
            // следующем поводе (идемпотентность waku)
            await trace.note(.error(domain: .llm))
        }
    }

    // MARK: Схема и промпт

    nonisolated struct ExtractedFact: Decodable, Sendable {
        let subject: String
        let content: String
    }

    nonisolated struct ConsolidationCall: Decodable, Sendable {
        let facts: [ExtractedFact]
        let episode: String
    }

    static let spec = StructuredSpec(jsonSchema: """
    {
      "type": "object",
      "properties": {
        "facts": {
          "type": "array",
          "maxItems": \(maxFactsPerRound),
          "items": {
            "type": "object",
            "properties": {
              "subject": {"type": "string"},
              "content": {"type": "string"}
            },
            "required": ["subject", "content"],
            "additionalProperties": false
          }
        },
        "episode": {"type": "string"}
      },
      "required": ["facts", "episode"],
      "additionalProperties": false
    }
    """)

    static func prompt(for chunk: [SophieMessage]) -> String {
        var lines = ["""
        Извлеки из фрагмента диалога ПРОЧНЫЕ факты о пользователе (имя, \
        близкие люди, места, предпочтения, планы) и одно предложение-резюме \
        эпизода. Факт — только то, что пользователь сказал явно; ничего не \
        выдумывай; нет фактов — пустой список. Не больше \
        \(maxFactsPerRound) фактов.
        Ответь ТОЛЬКО JSON вида \
        {"facts": [{"subject": "...", "content": "..."}], "episode": "..."}.
        Диалог:
        """]
        for message in chunk {
            lines.append((message.role == .user
                          ? "Пользователь: "
                          : "\(AppIdentity.assistantName): ") + message.text)
        }
        return lines.joined(separator: "\n")
    }

    /// Жёсткий потолок длины эпизода — обрезка кодом.
    static func clampChars(_ text: String,
                           limit: Int = maxEpisodeChars) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
