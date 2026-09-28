import Foundation

// ============================================================================
// ModelBackend — паспорт модели за LLMProvider (линия Софи, шаг 2).
//
// Харнесс Софи (цикл, трейс, память, эвал) не знает конкретную модель —
// только её возможности через этот паспорт. Деградация по возможностям,
// а не «все модели равны»: нет нативного tool-calling → текстовый
// протокол через StructuredLLM; маленький контекст → агрессивнее
// свёртка памяти. Смена модели — конфигом (LLMModelConfig), не правкой
// харнесса; сертификация смены — эвал-гейтом (шаг 4).
//
// Второго протокола рядом с LLMProvider НЕТ намеренно: LLMProvider уже
// и есть ModelBackend, здесь только его паспорт и новая возможность.
// ============================================================================

extension LLMCapabilities {
    /// Движок принимает описания инструментов и сам размечает tool-вызовы
    /// (llama.cpp/Qwen сейчас НЕ объявляют — выбор инструмента идёт
    /// текстовым протоколом через StructuredLLM).
    /// Биты 1<<0 и 1<<1 заняты structuredOutput и cancellation.
    static let nativeToolCalling = LLMCapabilities(rawValue: 1 << 2)
}

/// Всё, что харнесс должен знать о модели, не зная её имени.
nonisolated struct ModelBackendProfile: Equatable, Sendable {
    let contextLength: Int
    let nativeToolCalling: Bool
    let structuredOutput: Bool

    static func make(capabilities: LLMCapabilities,
                     contextLength: Int) -> ModelBackendProfile {
        ModelBackendProfile(
            contextLength: contextLength,
            nativeToolCalling: capabilities.contains(.nativeToolCalling),
            structuredOutput: capabilities.contains(.structuredOutput))
    }
}
