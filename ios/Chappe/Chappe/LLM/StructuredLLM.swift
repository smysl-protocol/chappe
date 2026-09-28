import Foundation

// ============================================================================
// StructuredLLM — единая точка входа для СЛУЖЕБНЫХ вызовов модели
// (SOS→JSON, сжатие, перевод с проверкой). Закрепляет принципы проекта
// на уровне абстракции:
//
//  - если провайдер умеет structured output — генерация идёт под грамматикой;
//  - если НЕ умеет — свободная генерация, а валидирует КОД с repair-попыткой;
//  - в обоих случаях результат парсится и валидируется кодом (грамматика
//    гарантирует формат, но не смысл — правило №8 CLAUDE.md);
//  - длину и потолки проверяет код, не модель (правила №3, №4).
// ============================================================================

nonisolated enum StructuredLLM {

    /// Служебный вызов со схемой.
    ///
    /// - T: Decodable-тип результата. Swift-enum в полях T сам по себе
    ///   отсекает значения вне допустимого набора при парсинге.
    /// - validate: дополнительная семантическая проверка (диапазоны,
    ///   потолки, согласованность полей). Кидает ошибку с ПОНЯТНЫМ текстом —
    ///   этот текст уходит модели в repair-промпт.
    /// - repairAttempts: сколько раз дать модели исправиться (по умолчанию 1).
    static func call<T: Decodable & Sendable>(
        provider: any LLMProvider,
        request: LLMRequest,
        spec: StructuredSpec,
        as type: T.Type,
        validate: @Sendable (T) throws -> Void = { _ in },
        repairAttempts: Int = 1
    ) async throws -> T {
        try await callRaw(provider: provider, request: request, spec: spec,
                          as: type, validate: validate,
                          repairAttempts: repairAttempts).value
    }

    /// Результат вместе с сырым JSON — для отладочных экранов.
    nonisolated struct Extracted<T: Sendable>: Sendable {
        let value: T
        let rawJSON: String
        let tokensPerSecond: Double
    }

    /// То же, что call, но возвращает и сырой JSON (как его отдала модель).
    static func callRaw<T: Decodable & Sendable>(
        provider: any LLMProvider,
        request: LLMRequest,
        spec: StructuredSpec,
        as type: T.Type,
        validate: @Sendable (T) throws -> Void = { _ in },
        repairAttempts: Int = 1
    ) async throws -> Extracted<T> {

        let constrained = provider.capabilities.contains(.structuredOutput)
        var lastFailure = "нет ответа"
        var currentRequest = request

        // Попытка 0 — основная; дальше repair-попытки.
        for attempt in 0...max(0, repairAttempts) {
            let response: LLMResponse
            if constrained {
                response = try await provider.generateStructured(currentRequest,
                                                                 spec: spec)
            } else {
                response = try await provider.generate(currentRequest)
            }

            switch Self.parseAndValidate(response.text, as: T.self,
                                         validate: validate) {
            case .success(let value, let json):
                return Extracted(value: value, rawJSON: json,
                                 tokensPerSecond: response.tokensPerSecond)
            case .failure(let reason):
                lastFailure = reason
                // Repair-промпт: показываем модели её ответ и причину отказа.
                // Схему повторяем текстом — enum-значения снова перед глазами.
                currentRequest = LLMRequest(
                    prompt: request.prompt
                        + "\n\nТвой прошлый ответ:\n\(response.text)\n"
                        + "Он не прошёл проверку: \(reason)\n"
                        + "Верни ТОЛЬКО исправленный JSON по схеме:\n\(spec.jsonSchema)",
                    systemPrompt: request.systemPrompt,
                    maxTokens: request.maxTokens,
                    samplingOverride: request.samplingOverride)
                _ = attempt // (номер попытки пригодится для логов)
            }
        }
        throw LLMError.invalidStructuredResult(reason: lastFailure)
    }

    // MARK: Внутренности

    private enum ParseOutcome<T> {
        case success(T, String)   // значение + вырезанный сырой JSON
        case failure(String)
    }

    private static func parseAndValidate<T: Decodable>(
        _ text: String, as type: T.Type,
        validate: (T) throws -> Void
    ) -> ParseOutcome<T> {
        guard let json = extractJSONObject(from: text),
              let data = json.data(using: .utf8) else {
            return .failure("в ответе не найден JSON-объект")
        }
        do {
            let value = try JSONDecoder().decode(T.self, from: data)
            try validate(value)
            return .success(value, json)
        } catch let err as DecodingError {
            return .failure("JSON не соответствует схеме: \(shortDecodingError(err))")
        } catch {
            return .failure(String(describing: error))
        }
    }

    /// Вырезает первый сбалансированный {...} из свободного текста —
    /// модели без грамматики любят обрамлять JSON пояснениями.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var prevWasEscape = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if prevWasEscape { prevWasEscape = false }
                else if ch == "\\" { prevWasEscape = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[start...i]) }
                default: break
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func shortDecodingError(_ err: DecodingError) -> String {
        switch err {
        case .keyNotFound(let key, _):
            return "нет обязательного поля '\(key.stringValue)'"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return "неверный тип/значение в поле '\(path)'"
        case .dataCorrupted(let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "повреждённый JSON"
                                : "недопустимое значение в поле '\(path)'"
        @unknown default:
            return "ошибка разбора JSON"
        }
    }
}
