import Foundation
import llama

// ============================================================================
// LlamaCppProvider — локальный движок: официальный llama.xcframework
// (релиз ggml-org/llama.cpp, пин b10107 — docs/llama_swift_plan.md §1).
//
// Фаза 1: load / generate (temp 0) / cancel. Схема (GBNF) — фаза 2.
// Параметры старта по плану: Metal on, mmap on (дефолты llama.cpp),
// контекст из конфига.
//
// Устройство: сам актор лёгкий; тяжёлая работа (декод токенов) идёт
// в LlamaRuntime на отдельной задаче, чтобы не блокировать пул потоков.
// Отмена — атомарный флаг, цикл проверяет его на каждом токене.
// ============================================================================

actor LlamaCppProvider: LLMProvider {

    nonisolated let kind: LLMProviderKind = .local

    // structuredOutput появится в фазе 2 (GBNF-грамматика зашитой строкой);
    // пока честно объявляем только отмену — служебные вызовы через
    // StructuredLLM автоматически пойдут путём «валидация + repair».
    nonisolated let capabilities: LLMCapabilities = [.cancellation]

    private(set) var isLoaded = false
    private var config: LLMModelConfig?
    private var runtime: LlamaRuntime?

    // Флаг отмены разделяется с рантаймом; выставляется из nonisolated.
    private nonisolated let cancelRequested = AtomicFlag()

    // MARK: Жизненный цикл

    func load(_ config: LLMModelConfig) async throws {
        if isLoaded { await unload() }

        let url = try config.resolvedModelURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LLMError.modelNotFound(path: url.path)
        }

        let contextLength = config.contextLength
        let path = url.path
        let cancelFlag = cancelRequested
        // Загрузка 0.5–2.5 ГБ весов — долгая; не держим её на акторе.
        let loaded = try await Task.detached(priority: .userInitiated) {
            try LlamaRuntime(modelPath: path, contextLength: contextLength,
                             cancelFlag: cancelFlag)
        }.value

        self.runtime = loaded
        self.config = config
        isLoaded = true
    }

    func unload() async {
        runtime = nil     // deinit рантайма освобождает контекст и модель
        config = nil
        isLoaded = false
    }

    // MARK: Генерация

    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        try await run(request, onToken: nil)
    }

    func generateStreaming(_ request: LLMRequest,
                           onToken: @escaping @Sendable (String) -> Void)
        async throws -> LLMResponse {
        try await run(request, onToken: onToken)
    }

    private func run(_ request: LLMRequest,
                     onToken: (@Sendable (String) -> Void)?) async throws -> LLMResponse {
        guard isLoaded, let runtime, let config else {
            throw LLMError.modelNotLoaded
        }
        cancelRequested.clear()
        let sampling = request.samplingOverride ?? config.sampling
        return try await Task.detached(priority: .userInitiated) {
            try runtime.generate(prompt: request.prompt,
                                 systemPrompt: request.systemPrompt,
                                 assistantPrefix: request.assistantPrefix,
                                 maxTokens: request.maxTokens,
                                 sampling: sampling,
                                 onToken: onToken)
        }.value
    }

    func generateStructured(_ request: LLMRequest,
                            spec: StructuredSpec) async throws -> LLMResponse {
        // Фаза 2: llama_sampler_init_grammar с предкомпилированной GBNF.
        throw LLMError.structuredOutputUnsupported
    }

    nonisolated func cancelActiveGeneration() {
        cancelRequested.set()
    }
}

// ============================================================================
// LlamaRuntime — владение C-объектами llama.cpp и синхронный цикл декода.
// @unchecked Sendable: указатели используются последовательно (один
// вызов generate за раз — гарантирует актор выше).
// ============================================================================

nonisolated final class LlamaRuntime: @unchecked Sendable {

    private let model: OpaquePointer          // llama_model
    private let context: OpaquePointer        // llama_context
    private let vocab: OpaquePointer          // llama_vocab
    private let cancelFlag: AtomicFlag
    private let contextLength: Int

    // KV-кэш «тёплого контекста» (фаза 2, sophie_presence §5): токены,
    // уже прогнанные через модель в текущем состоянии KV. Новый вызов
    // находит общий префикс со своим промптом (у служебных вызовов это
    // весь шаблон + системный PIVOT-промпт, ~сотни токенов), срезает
    // хвост KV (llama_memory_seq_rm) и декодирует только новое.
    private var cachedTokens: [llama_token] = []

    init(modelPath: String, contextLength: Int, cancelFlag: AtomicFlag) throws {
        self.cancelFlag = cancelFlag
        self.contextLength = contextLength

        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999            // Metal: все слои на GPU
        // mmap включён по умолчанию — веса не дублируются в RAM целиком

        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LLMError.modelLoadFailed(
                reason: "llama.cpp не открыл модель: \(modelPath)")
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextLength)

        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LLMError.modelLoadFailed(reason: "не создался контекст модели")
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw LLMError.modelLoadFailed(reason: "у модели нет словаря токенов")
        }

        self.model = model
        self.context = context
        self.vocab = vocab
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    // MARK: Синхронная генерация (вызывается с detached-задачи)

    func generate(prompt: String, systemPrompt: String?,
                  assistantPrefix: String? = nil,
                  maxTokens: Int, sampling: SamplingParams,
                  onToken: (@Sendable (String) -> Void)? = nil) throws -> LLMResponse {

        // Префикс ассистента дописывается ПОСЛЕ заголовка ассистента из
        // шаблона — модель продолжает свой оборванный ответ. Для чата,
        // остановленного стопом, эти токены уже в KV-кэше (генерация
        // кэшируется) — prefill почти нулевой.
        let fullPrompt = applyChatTemplate(system: systemPrompt, user: prompt)
            + (assistantPrefix ?? "")
        let tokens = try tokenize(fullPrompt)

        // Промпт обязан влезать в контекст с запасом под ответ
        guard tokens.count + maxTokens < contextLength else {
            throw LLMError.generationFailed(
                reason: "промпт \(tokens.count) ток. + ответ \(maxTokens) "
                      + "не влезают в контекст \(contextLength)")
        }

        // Тёплый контекст: общий префикс с прошлым вызовом остаётся в KV.
        // Минимум один токен промпта декодируем всегда — нужны свежие логиты.
        let memory = llama_get_memory(context)
        var common = 0
        while common < min(cachedTokens.count, tokens.count - 1),
              cachedTokens[common] == tokens[common] {
            common += 1
        }
        if common > 0 {
            llama_memory_seq_rm(memory, 0, llama_pos(common), -1)
        } else {
            llama_memory_clear(memory, true)
        }
        var suffix = Array(tokens[common...])
        cachedTokens = tokens

        let sampler = makeSampler(sampling)
        defer { llama_sampler_free(sampler) }

        // Prefill: только хвост после общего префикса (позиции продолжаются
        // от состояния KV — batch_get_one без pos продолжает последовательность).
        // КРИТИЧНО: чанками ≤512 — llama_decode с батчем больше n_batch
        // роняет процесс GGML-ассертом (крэш шёпота 28.07: промпт с длинным
        // транскриптом ≈ 2500 токенов > n_batch 2048). Заодно prefill стал
        // прерываемым между чанками.
        let prefillStart = DispatchTime.now()
        var batch: llama_batch
        var offset = 0
        while offset < suffix.count {
            if cancelFlag.isSet {
                cachedTokens = []
                llama_memory_clear(memory, true)
                throw LLMError.cancelled
            }
            let count = min(512, suffix.count - offset)
            var chunk = Array(suffix[offset..<(offset + count)])
            batch = llama_batch_get_one(&chunk, Int32(count))
            guard llama_decode(context, batch) == 0 else {
                cachedTokens = []
                llama_memory_clear(memory, true)
                throw LLMError.generationFailed(reason: "decode промпта не удался")
            }
            offset += count
        }
        let prefillMillis = Double(DispatchTime.now().uptimeNanoseconds
                                   - prefillStart.uptimeNanoseconds) / 1e6

        // Цикл декода: токен за токеном, с проверкой отмены.
        // pendingBytes копит байты до валидной UTF-8 границы: токен может
        // резать многобайтовый символ пополам — наружу уходят только целые.
        var produced: [UInt8] = []
        var pendingBytes: [UInt8] = []
        var generated = 0
        var finish = LLMFinishReason.length
        let started = DispatchTime.now()

        while generated < maxTokens {
            if cancelFlag.isSet || Task.isCancelled {
                finish = .cancelled
                break
            }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                finish = .stop
                break
            }
            let bytes = piece(for: token)
            produced.append(contentsOf: bytes)
            if let onToken {
                pendingBytes.append(contentsOf: bytes)
                if let chunk = String(bytes: pendingBytes, encoding: .utf8) {
                    onToken(chunk)
                    pendingBytes.removeAll(keepingCapacity: true)
                }
            }
            generated += 1

            batch = llama_batch_get_one(&token, 1)
            guard llama_decode(context, batch) == 0 else {
                cachedTokens = []
                llama_memory_clear(memory, true)
                throw LLMError.generationFailed(reason: "decode токена не удался")
            }
            cachedTokens.append(token)   // токен вошёл в KV — учитываем в кэше
        }

        if finish == .cancelled {
            throw LLMError.cancelled
        }

        let seconds = Double(DispatchTime.now().uptimeNanoseconds
                             - started.uptimeNanoseconds) / 1e9
        let text = String(decoding: produced, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMResponse(text: text,
                           tokensGenerated: generated,
                           tokensPerSecond: seconds > 0 ? Double(generated) / seconds : 0,
                           finishReason: finish,
                           prefillMillis: prefillMillis)
    }

    // MARK: Внутренности

    /// Chat-шаблон из метаданных GGUF (у каждой модели свой). Если шаблона
    /// нет или он не применился — промпт уходит как есть.
    private func applyChatTemplate(system: String?, user: String) -> String {
        guard let tmpl = llama_model_chat_template(model, nil) else { return user }

        var messages: [llama_chat_message] = []
        var keepAlive: [UnsafeMutablePointer<CChar>] = []   // владение C-строками
        defer { keepAlive.forEach { free($0) } }

        func add(role: String, content: String) {
            let r = strdup(role)!, c = strdup(content)!
            keepAlive.append(r); keepAlive.append(c)
            messages.append(llama_chat_message(role: UnsafePointer(r),
                                               content: UnsafePointer(c)))
        }
        if let system { add(role: "system", content: system) }
        add(role: "user", content: user)

        var capacity = max(1024, (user.utf8.count + (system?.utf8.count ?? 0)) * 2 + 512)
        for _ in 0..<3 {
            var buf = [CChar](repeating: 0, count: capacity)
            let written = llama_chat_apply_template(tmpl, &messages, messages.count,
                                                    true, &buf, Int32(capacity))
            if written < 0 { return user }          // шаблон не применился
            if Int(written) <= capacity {
                return String(decoding: buf[0..<Int(written)].map { UInt8(bitPattern: $0) },
                              as: UTF8.self)
            }
            capacity = Int(written) + 1             // буфер был мал — растим
        }
        return user
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let bytes = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: bytes.count + 16)
        let count = llama_tokenize(vocab, text, Int32(bytes.count),
                                   &tokens, Int32(tokens.count),
                                   true,   // add_special (BOS по правилам модели)
                                   true)   // parse_special (теги шаблона)
        guard count >= 0 else {
            throw LLMError.generationFailed(reason: "токенизация не удалась")
        }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(for token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 128)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        guard n > 0 else { return [] }
        return buf[0..<Int(n)].map { UInt8(bitPattern: $0) }
    }

    /// Цепочка сэмплеров. temp 0 или top-k 1 → жадный выбор (наш пресет
    /// .extraction); иначе — top-k/top-p/min-p/temp + dist, как в бенчмарках.
    private func makeSampler(_ s: SamplingParams) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        if s.temperature <= 0 || s.topK == 1 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(s.topK)))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(s.topP), 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(s.minP), 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(s.temperature)))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        }
        return chain!
    }
}
