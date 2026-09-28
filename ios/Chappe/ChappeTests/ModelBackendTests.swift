import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Паспорт модели (шаг 2 линии Софи): харнесс знает возможности, не имя.
// Ожидание извне: биты возможностей из docs/llm_architecture.md —
// structuredOutput = 1<<0, cancellation = 1<<1; новая nativeToolCalling
// обязана быть ОТДЕЛЬНЫМ битом, не коллизией с существующими.
// ============================================================================

struct ModelBackendTests {

    @Test("паспорт отражает возможности и контекст провайдера")
    func profileReflectsCapabilities() {
        let bare = ModelBackendProfile.make(capabilities: [.cancellation],
                                            contextLength: 4096)
        #expect(bare.contextLength == 4096)
        #expect(!bare.nativeToolCalling,
                "llama.cpp сегодня не объявляет нативный tool-calling")
        #expect(!bare.structuredOutput)

        let rich = ModelBackendProfile.make(
            capabilities: [.nativeToolCalling, .structuredOutput],
            contextLength: 8192)
        #expect(rich.contextLength == 8192)
        #expect(rich.nativeToolCalling)
        #expect(rich.structuredOutput)
    }

    @Test("nativeToolCalling — отдельный бит, не коллизия с существующими")
    func nativeToolCallingIsDistinctBit() {
        let existing: LLMCapabilities = [.structuredOutput, .cancellation]
        #expect(!existing.contains(.nativeToolCalling), Comment(rawValue:
                "перекрытие битов сделало бы «умеет structured output» "
                + "неотличимым от «умеет нативные инструменты» — харнесс "
                + "деградировал бы не по той возможности"))
        #expect(LLMCapabilities.nativeToolCalling.rawValue
                != LLMCapabilities.structuredOutput.rawValue)
        #expect(LLMCapabilities.nativeToolCalling.rawValue
                != LLMCapabilities.cancellation.rawValue)
    }
}
