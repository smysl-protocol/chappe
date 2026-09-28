import Foundation

// ============================================================================
// LLMProvider — единая абстракция над локальной языковой моделью.
//
// Смысл: модель и движок — заменяемые детали. Приложение говорит только
// с этим протоколом и не знает, что за ним — llama.cpp, MLX или что-то
// третье. Выбор модели приходит из конфига (LLMModelConfig), не из кода.
// Решение описано в docs/llm_architecture.md.
// ============================================================================

/// Тип движка. Новый движок = новый case + ветка в LLMProviderFactory.
/// `.local` — критерий гейта приватности (sophie_presence §3): обещание
/// «ноль байт с устройства» действует только при локальном провайдере.
nonisolated enum LLMProviderKind: String, Codable, Sendable {
    case local      // llama.cpp на устройстве (GGUF, GBNF) — основной путь
    case mlx        // MLX (быстрее на Apple Silicon) — задел, пока не реализован
    case remote     // llama-server по сети (разработка: модель на Маке)
}

/// Возможности, которые провайдер объявляет о себе.
///
/// Ключевое: structuredOutput — НЕ обязателен. Грамматика на уровне сэмплера
/// есть у llama.cpp, но может отсутствовать у другого движка. Код служебных
/// вызовов обязан проверять эту возможность и, если её нет, валидировать
/// результат сам с repair-попыткой (см. StructuredLLM).
nonisolated struct LLMCapabilities: OptionSet, Sendable {
    let rawValue: Int

    /// Жёсткая схема на уровне сэмплера (грамматика зануляет недопустимые токены).
    static let structuredOutput = LLMCapabilities(rawValue: 1 << 0)
    /// Провайдер умеет прерывать генерацию на полпути.
    static let cancellation     = LLMCapabilities(rawValue: 1 << 1)
}

/// Ошибки всего LLM-слоя. С associated values — поэтому без Equatable;
/// для проверок в UI использовать сопоставление по case.
nonisolated enum LLMError: Error {
    case modelNotFound(path: String)
    case modelLoadFailed(reason: String)
    case modelNotLoaded
    case generationFailed(reason: String)
    case cancelled
    /// Провайдер не умеет structured output — вызывающий обязан идти
    /// через StructuredLLM (валидация + repair), а не сюда напрямую.
    case structuredOutputUnsupported
    /// Результат не прошёл валидацию кодом (и repair-попытки исчерпаны).
    case invalidStructuredResult(reason: String)
    /// Провайдер объявлен, но реализация ещё не подключена.
    case providerUnavailable(reason: String)
}

/// Ф5.4 (бриф 31.07): без этого любое место, показывающее
/// localizedDescription, печатало «RM.LLMError error 1» — код вместо
/// причины. Теперь ошибка всегда словами.
extension LLMError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            "Файл модели не найден: \(path)"
        case .modelLoadFailed(let reason):
            "Модель не загрузилась: \(reason)"
        case .modelNotLoaded:
            "Модель не загружена — повторите попытку."
        case .generationFailed(let reason):
            "Генерация не удалась: \(reason)"
        case .cancelled:
            "Отменено."
        case .structuredOutputUnsupported:
            "Этот провайдер не поддерживает жёсткую схему."
        case .invalidStructuredResult(let reason):
            "Модель не дала корректный результат: \(reason)"
        case .providerUnavailable(let reason):
            "Провайдер недоступен: \(reason)"
        }
    }
}

/// Причина завершения генерации.
nonisolated enum LLMFinishReason: Sendable {
    case stop        // модель закончила сама
    case length      // упёрлись в maxTokens
    case cancelled   // прервали
}

/// Один запрос на генерацию. Chat-шаблон применяет ПРОВАЙДЕР —
/// вызывающий код о шаблонах не знает (у каждой модели свой).
nonisolated struct LLMRequest: Sendable {
    var prompt: String
    var systemPrompt: String?
    var maxTokens: Int
    /// Переопределение сэмплинга для этого запроса (например, temp 0.2
    /// для SOS-извлечения). nil — параметры из конфига модели.
    var samplingOverride: SamplingParams?
    /// Начало ответа ассистента — модель ПРОДОЛЖАЕТ этот текст
    /// («Продолжить» после стопа). Локальный движок дописывает его
    /// после заголовка ассистента в chat-шаблоне; тёплый KV делает
    /// префикс почти бесплатным (частичный ответ уже в кэше).
    var assistantPrefix: String?

    init(prompt: String,
         systemPrompt: String? = nil,
         maxTokens: Int = 200,
         samplingOverride: SamplingParams? = nil,
         assistantPrefix: String? = nil) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.samplingOverride = samplingOverride
        self.assistantPrefix = assistantPrefix
    }
}

/// Результат генерации.
nonisolated struct LLMResponse: Sendable {
    var text: String
    var tokensGenerated: Int
    var tokensPerSecond: Double
    var finishReason: LLMFinishReason
    /// Время обработки промпта (prefill) в миллисекундах; 0 — если
    /// провайдер его не сообщает (remote отдаёт только общую скорость).
    var prefillMillis: Double = 0
}

/// Спецификация структурированного вывода.
///
/// Канонический источник — JSON Schema (с enum и потолками maxItems,
/// правила №2 и №3 CLAUDE.md). GBNF — предкомпилированная грамматика для
/// llama.cpp: для статических схем (SOS) генерируется ОФЛАЙН скриптом
/// json_schema_to_grammar.py и зашивается строкой — конвертер на устройстве
/// не нужен.
nonisolated struct StructuredSpec: Sendable {
    var jsonSchema: String
    var gbnf: String?

    init(jsonSchema: String, gbnf: String? = nil) {
        self.jsonSchema = jsonSchema
        self.gbnf = gbnf
    }
}

// MARK: - Протокол провайдера

/// Провайдер — actor: генерация долгая и с внутренним состоянием (контекст
/// модели), actor даёт последовательный доступ без ручных замков.
///
/// Отмена — двумя путями:
///  1) кооперативно: отменить Task, в котором идёт generate (провайдер
///     обязан проверять Task.isCancelled по ходу генерации);
///  2) явно: cancelActiveGeneration() — nonisolated, можно дёрнуть из UI
///     («Стоп»), пока generate ещё выполняется.
nonisolated protocol LLMProvider: Actor {
    /// Какой это движок (для логов и настроек).
    nonisolated var kind: LLMProviderKind { get }

    /// Что провайдер умеет. Проверять ДО вызова generateStructured.
    nonisolated var capabilities: LLMCapabilities { get }

    var isLoaded: Bool { get }

    /// Загрузить модель по пути из конфига. Повторный вызов с другой
    /// моделью — сначала выгружает старую.
    func load(_ config: LLMModelConfig) async throws

    /// Выгрузить модель и освободить память (важно на iOS: jetsam).
    func unload() async

    /// Свободная генерация (чат, переводы, черновики сжатия).
    func generate(_ request: LLMRequest) async throws -> LLMResponse

    /// Генерация под жёсткой схемой. Если .structuredOutput не объявлен —
    /// кидает LLMError.structuredOutputUnsupported.
    /// ВАЖНО (правило №8 CLAUDE.md): допустимые enum-значения должны быть
    /// перечислены в тексте промпта — грамматика гарантирует формат, но не смысл.
    func generateStructured(_ request: LLMRequest,
                            spec: StructuredSpec) async throws -> LLMResponse

    /// Прервать текущую генерацию (если идёт). Безопасно звать всегда.
    nonisolated func cancelActiveGeneration()

    /// Свободная генерация со стримингом: onToken получает читаемые куски
    /// текста по мере генерации (для чата — печать в пузырь). Провайдер
    /// без стриминга наследует дефолт: обычный generate, всё одним куском.
    func generateStreaming(_ request: LLMRequest,
                           onToken: @escaping @Sendable (String) -> Void)
        async throws -> LLMResponse
}

extension LLMProvider {
    /// Дефолт для провайдеров без стриминга (remote и будущие).
    func generateStreaming(_ request: LLMRequest,
                           onToken: @escaping @Sendable (String) -> Void)
        async throws -> LLMResponse {
        let response = try await generate(request)
        onToken(response.text)
        return response
    }
}
