import Foundation

// ============================================================================
// Гейт извлечения памяти (шаг 3.2, самый ценный кусок постановки):
// дешёвый решатель «нужна ли этому ходу память?» ДО поиска и ДО того,
// как блок памяти съест бюджет промпта.
//
// Двухступенчатый — адаптация waku под телефон: у waku гейт — вызов
// малой модели, у нас малой модели нет (только 4B), поэтому сначала
// ЭВРИСТИКИ КОДОМ (бесплатно), и лишь неоднозначное эскалируется в
// короткий structured-вызов ≤80 токенов. Требование владельца 21.08:
// смысл гейта — НИЗКАЯ частота эскалаций, цифры видны в трейсе
// (gate_h/gate_m в пульсе SophieTrace).
//
// FAIL-OPEN (паттерн waku): любой сбой модельного вызова → искать по
// исходному тексту. Пропущенный факт дороже лишнего поиска (в
// cost-weighted эвале шага 4 — вчетверо).
// ============================================================================

nonisolated struct SophieRetrievalGate: Sendable {

    var scheduler: ModelScheduler = .shared
    var trace: SophieTrace = .shared

    nonisolated struct Decision: Equatable, Sendable {
        let retrieve: Bool
        /// Что искать (эвристики ищут по исходному тексту; модель может
        /// переформулировать — второй бонус гейта из waku).
        let query: String
        let route: SophieTrace.GateRoute
    }

    /// memoryIsEmpty — дешёвый сигнал от стора: пустую память не ищут.
    func decide(for text: String, memoryIsEmpty: Bool) async -> Decision {
        if memoryIsEmpty {
            await trace.note(.gate(route: .heuristic))
            return Decision(retrieve: false, query: "", route: .heuristic)
        }
        if let sure = Self.heuristicDecision(for: text) {
            await trace.note(.gate(route: .heuristic))
            return Decision(retrieve: sure, query: sure ? text : "",
                            route: .heuristic)
        }
        await trace.note(.gate(route: .model))
        do {
            let request = LLMRequest(prompt: Self.gatePrompt(for: text),
                                     maxTokens: 80,
                                     samplingOverride: .extraction)
            let call = try await scheduler.withProvider(.interactive) { provider in
                try await StructuredLLM.call(provider: provider,
                                             request: request,
                                             spec: Self.gateSpec,
                                             as: GateCall.self)
            }
            let query = (call.query?.isEmpty == false) ? call.query! : text
            return Decision(retrieve: call.retrieve,
                            query: call.retrieve ? query : "",
                            route: .model)
        } catch {
            // Fail-open: сбой гейта не закрывает память
            return Decision(retrieve: true, query: text, route: .model)
        }
    }

    // MARK: Ступень 1 — эвристики кодом

    /// Светская беседа: точное совпадение нормализованной реплики.
    static let greetings: Set<String> = [
        "привет", "приветик", "здравствуй", "здравствуйте",
        "добрый день", "добрый вечер", "доброе утро", "доброй ночи",
        "спасибо", "спасибо большое", "благодарю", "пока", "до встречи",
        "ок", "окей", "хорошо", "ладно", "да", "нет", "ага", "угу",
        "hi", "hello", "hey", "thanks", "thank you", "ok", "bye",
    ]

    /// Маркеры обращения к прошлому/личному: подстрока в нижнем регистре.
    /// Ложное «да» дёшево (лишний поиск), пропуск дорог — список щедрый.
    /// Пополнено 22.08 по промахам ночного эвала (FN p04 «куда положили»)
    /// и падежами притяжательных.
    static let memoryMarkers: [String] = [
        "помнишь", "помните", "запомни", "не забудь",
        "я говорил", "я говорила", "я тебе", "я уже расска",
        "мы обсуждали", "мы говорили", "в прошлый раз", "раньше",
        "как меня зовут", "моё имя", "мое имя",
        "мой ", "моя ", "моё ", "мое ", "мои ",
        "мою ", "моего ", "моей ", "моих ", "моим ", "у меня ",
        "куда положил", "куда убрали", "где лежит", "где лежат",
        // Родня = личный контекст (закрыло FN p06/p07 эвала 22.08).
        // Ведущий пробел — граница слова; при проверке к тексту
        // добавляется пробел слева, чтобы ловить и первое слово.
        " жена", " жене", " жену", " женой", " муж ", " мужа", " мужу",
        " мужем", " сын", " дочь", " дочк", " брат", " сестр",
        " мама", " маме", " мамы", " мам ", " папа", " папе", " папы",
        " бабушк", " дедушк", " родител",
    ]

    /// Вопросы про устройство — их закрывают инструменты, память не
    /// нужна (снижение эскалаций 22.08). Проверяются ПОСЛЕ маркеров
    /// памяти: «куда положили батарейки» — личное, не батарея.
    static let deviceMarkers: [String] = [
        "батаре", "заряд", "скачана ли карта",
        "погод",   // погоду закрывает инструмент weather, не память
    ]

    /// Чистая эвристическая ступень: true/false — уверенное решение,
    /// nil — неоднозначно (эскалация в модель).
    static func heuristicDecision(for text: String) -> Bool? {
        let lower = " " + text.lowercased()
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        if greetings.contains(normalized) { return false }
        if memoryMarkers.contains(where: { lower.contains($0) }) {
            return true
        }
        if deviceMarkers.contains(where: { lower.contains($0) }) {
            return false
        }
        return nil
    }

    // MARK: Ступень 2 — короткий вызов модели

    private nonisolated struct GateCall: Decodable, Sendable {
        let retrieve: Bool
        let query: String?
    }

    static let gateSpec = StructuredSpec(jsonSchema: """
    {
      "type": "object",
      "properties": {
        "retrieve": {"type": "boolean"},
        "query": {"type": "string"}
      },
      "required": ["retrieve"],
      "additionalProperties": false
    }
    """)

    static func gatePrompt(for message: String) -> String {
        """
        Реши, нужна ли долговременная память о пользователе, чтобы \
        хорошо ответить на сообщение. Ответь ТОЛЬКО JSON вида \
        {"retrieve": true, "query": "что искать"} или {"retrieve": false}.
        - retrieve=true: сообщение касается жизни пользователя, его людей, \
        планов, прошлых разговоров, предпочтений
        - retrieve=false: общие знания, шутки, математика, погода, \
        самодостаточный вопрос
        Сообщение: \(message)
        """
    }
}

/// Блок памяти для промпта финального вызова.
nonisolated enum SophieMemoryBlock {

    /// nil — нечего вставлять (пустые результаты).
    static func compose(facts: [SophieFact],
                        episodes: [SophieEpisode]) -> String? {
        if facts.isEmpty && episodes.isEmpty { return nil }
        var lines = ["Память Софи — факты из прошлых разговоров (если "
                     + "пользователь говорит иначе — верь пользователю):"]
        for fact in facts {
            lines.append("- \(fact.subject): \(fact.content)")
        }
        if !episodes.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM"
            for episode in episodes {
                lines.append("- (\(formatter.string(from: episode.happenedAt))) "
                             + episode.summary)
            }
        }
        return lines.joined(separator: "\n")
    }
}
