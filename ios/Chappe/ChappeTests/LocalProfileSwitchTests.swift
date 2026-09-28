import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Баг 02.08 (скрины владельца): модель установлена, а гейт Софи просит
// «переключиться на локальную» — активным оставался сетевой профиль,
// и ни Помощник, ни кнопка гейта его не меняли. Фикс: общая
// activateLocalIfInstalled(); тесты аккуратно сохраняют и
// восстанавливают реальный llm_config.json и каталог моделей.
// ============================================================================

@Suite(.serialized)   // общие файлы: llm_config.json + каталог моделей
nonisolated struct LocalProfileSwitchTests {

    /// Ревизия параллелизма 06.08: тест уходит во ВРЕМЕННЫЙ каталог
    /// моделей. Раньше он писал настоящий `llm_config.json`, который
    /// параллельно читали соседние сюиты (ModelScheduler) — отсюда
    /// флейк «активация не открыла гейт» в полном прогоне при зелёном
    /// в изоляции. Настоящий конфиг устройства больше не трогается.
    private func withConfigRestored(_ body: () throws -> Void) throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChappeModelsTest-\(UUID().uuidString)",
                                    isDirectory: true)
        LLMModelConfig.directoryOverride = temp
        defer {
            LLMModelConfig.directoryOverride = nil
            try? FileManager.default.removeItem(at: temp)
        }
        try body()
    }

    @Test("модель установлена → активация чинит гейт одним вызовом")
    func activationOpensGateWhenModelInstalled() throws {
        try withConfigRestored {
            let dir = try LLMModelConfig.modelsDirectory()
            let fake = dir.appendingPathComponent("test_fake_model.gguf")
            let hadModels = !ModelStore.installedModels().isEmpty
            if !hadModels {
                try Data("gguf".utf8).write(to: fake)
            }
            defer { if !hadModels { try? FileManager.default.removeItem(at: fake) } }

            // репро бага: активен сетевой dev-профиль при стоящей модели
            try LLMModelConfig.remoteDev.saveAsActive()
            #expect(!ModelScheduler.isLocalProviderActive(),
                    "прекондиция: гейт закрыт")

            // фикс: один вызов — профиль локальный, гейт открыт
            let activated = LLMModelConfig.activateLocalIfInstalled()
            #expect(activated != nil)
            #expect(activated?.providerKind == .local)
            #expect(ModelScheduler.isLocalProviderActive(),
                    "гейт обязан открыться")
            // и конфиг указывает на реально стоящий файл
            let file = try #require(activated?.modelFile)
            #expect(ModelStore.installedModels()
                .contains { $0.lastPathComponent == file })
        }
    }

    @Test("модели нет → профиль не трогается, возврат nil")
    func withoutModelNothingChanges() throws {
        try withConfigRestored {
            let dir = try LLMModelConfig.modelsDirectory()
            // спрятать реальные модели нельзя — тест осмыслен только
            // в окружении без моделей; иначе честно пропускаем
            guard ModelStore.installedModels().isEmpty else { return }
            try LLMModelConfig.remoteDev.saveAsActive()
            #expect(LLMModelConfig.activateLocalIfInstalled() == nil)
            #expect(!ModelScheduler.isLocalProviderActive(),
                    "без модели профиль обязан остаться прежним")
            _ = dir
        }
    }
}
