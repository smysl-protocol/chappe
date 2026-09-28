import Foundation

// ============================================================================
// RemoteProvider — LLM по сети: llama-server на Маке (разработческий путь).
//
// Зачем: увидеть сквозной поток SOS→JSON на живом телефоне СЕГОДНЯ,
// не дожидаясь интеграции llama.swift. Телефон и Мак в одной Wi-Fi,
// сервер слушает порт 8080 (см. docs/remote_llm_setup.md).
//
// Схема выполняется НА СЕРВЕРЕ: llama-server принимает json_schema и сам
// строит по ней грамматику (тот же путь, что в tools/bench_http.py, тест №6).
// Поэтому capability structuredOutput = да.
//
// Это НЕ продакшен-путь: продакшен — модель на устройстве (LlamaCppProvider).
// ============================================================================

actor RemoteProvider: LLMProvider {

    nonisolated let kind: LLMProviderKind = .remote
    nonisolated let capabilities: LLMCapabilities = [.structuredOutput,
                                                     .cancellation]

    private(set) var isLoaded = false
    private var config: LLMModelConfig?
    private var baseURL: URL?

    // Отмена: храним замыкание, рвущее текущий HTTP-запрос.
    private nonisolated let activeCall = ActiveCallBox()

    // MARK: Жизненный цикл

    func load(_ config: LLMModelConfig) async throws {
        guard let host = config.host, let url = URL(string: host) else {
            throw LLMError.modelLoadFailed(
                reason: "в конфиге не задан host llama-server")
        }
        // «Загрузка» удалённой модели = проверка, что сервер жив.
        var req = URLRequest(url: url.appendingPathComponent("health"))
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw LLMError.modelLoadFailed(
                    reason: "llama-server отвечает, но нездоров (\(host))")
            }
        } catch let err as LLMError {
            throw err
        } catch {
            throw LLMError.modelLoadFailed(
                reason: "llama-server недоступен на \(host): "
                      + error.localizedDescription)
        }
        self.baseURL = url
        self.config = config
        isLoaded = true
    }

    func unload() async {
        // Модель живёт на сервере — освобождать на телефоне нечего.
        isLoaded = false
        config = nil
        baseURL = nil
    }

    // MARK: Генерация

    /// Свободная генерация — через /v1/chat/completions
    /// (сервер сам применяет chat-шаблон модели).
    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        guard isLoaded, let base = baseURL, let cfg = config else {
            throw LLMError.modelNotLoaded
        }
        let s = request.samplingOverride ?? cfg.sampling

        var messages: [[String: Any]] = []
        if let sys = request.systemPrompt {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": request.prompt])
        if let prefix = request.assistantPrefix {
            // Приближение продолжения для dev-сервера: частичный ответ
            // уходит assistant-сообщением (сервер откроет новый ход —
            // точный префикс умеет только локальный движок)
            messages.append(["role": "assistant", "content": prefix])
        }

        let payload: [String: Any] = [
            "messages": messages,
            "max_tokens": request.maxTokens,
            "temperature": s.temperature,
            "top_p": s.topP,
            "top_k": s.topK,
            "min_p": s.minP,
        ]
        let json = try await post(base.appendingPathComponent("v1/chat/completions"),
                                  payload: payload)

        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.generationFailed(reason: "неожиданный ответ сервера")
        }
        let finish = (choices.first?["finish_reason"] as? String) == "length"
                   ? LLMFinishReason.length : .stop
        return LLMResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                           tokensGenerated: completionTokens(json),
                           tokensPerSecond: tokensPerSecond(json),
                           finishReason: finish)
    }

    /// Генерация под схемой — через /completion с json_schema:
    /// сервер строит грамматику по схеме и жёстко ограничивает сэмплер
    /// (проверенный путь бенчмарка, тест №6).
    func generateStructured(_ request: LLMRequest,
                            spec: StructuredSpec) async throws -> LLMResponse {
        guard isLoaded, let base = baseURL, let cfg = config else {
            throw LLMError.modelNotLoaded
        }
        guard let schemaData = spec.jsonSchema.data(using: .utf8),
              let schemaObj = try? JSONSerialization.jsonObject(with: schemaData) else {
            throw LLMError.generationFailed(reason: "не разобралась JSON Schema")
        }
        let s = request.samplingOverride ?? cfg.sampling

        // /completion принимает сырой промпт; system приклеиваем сверху.
        var prompt = request.prompt
        if let sys = request.systemPrompt { prompt = sys + "\n\n" + prompt }

        let payload: [String: Any] = [
            "prompt": prompt,
            "n_predict": request.maxTokens,
            "temperature": s.temperature,
            "top_p": s.topP,
            "top_k": s.topK,
            "min_p": s.minP,
            "json_schema": schemaObj,
        ]
        let json = try await post(base.appendingPathComponent("completion"),
                                  payload: payload)

        guard let text = json["content"] as? String, !text.isEmpty else {
            throw LLMError.generationFailed(reason: "сервер вернул пустой ответ")
        }
        return LLMResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                           tokensGenerated: completionTokens(json),
                           tokensPerSecond: tokensPerSecond(json),
                           finishReason: .stop)
    }

    nonisolated func cancelActiveGeneration() {
        activeCall.cancel()
    }

    // MARK: HTTP

    private func post(_ url: URL,
                      payload: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 180   // генерация бывает долгой

        // Двойная отмена: кооперативная (отмена внешнего Task) и явная
        // (cancelActiveGeneration из UI) — обе рвут внутренний Task с запросом.
        let call = Task { try await URLSession.shared.data(for: req) }
        activeCall.store { call.cancel() }
        defer { activeCall.clear() }

        do {
            let (data, resp) = try await withTaskCancellationHandler {
                try await call.value
            } onCancel: {
                call.cancel()
            }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw LLMError.generationFailed(
                    reason: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0): "
                          + body.prefix(200))
            }
            guard let json = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                throw LLMError.generationFailed(reason: "ответ сервера — не JSON")
            }
            return json
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let err as URLError where err.code == .cancelled {
            throw LLMError.cancelled
        } catch let err as LLMError {
            throw err
        } catch {
            throw LLMError.generationFailed(reason: error.localizedDescription)
        }
    }

    /// Скорость из поля timings сервера (именно скорость генерации).
    private func tokensPerSecond(_ json: [String: Any]) -> Double {
        let timings = json["timings"] as? [String: Any]
        return (timings?["predicted_per_second"] as? Double) ?? 0
    }

    private func completionTokens(_ json: [String: Any]) -> Int {
        if let usage = json["usage"] as? [String: Any],
           let n = usage["completion_tokens"] as? Int { return n }
        if let timings = json["timings"] as? [String: Any],
           let n = timings["predicted_n"] as? Int { return n }
        return 0
    }
}

// MARK: - Хранилище отмены текущего запроса

/// Потокобезопасная коробка с замыканием «оборвать текущий HTTP-запрос».
nonisolated final class ActiveCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    func store(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        onCancel = handler
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        onCancel = nil
    }

    func cancel() {
        lock.lock(); let handler = onCancel; lock.unlock()
        handler?()
    }
}
