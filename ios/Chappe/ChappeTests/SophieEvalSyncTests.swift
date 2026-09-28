import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Синхронность промптов с эвал-гейтом (шаг 4): файлы-эталоны в
// tools/sophie_eval/prompts/ — ЕДИНЫЙ источник для Python-эвала
// (run_gate.py) и рантайма Софи. Паттерн общих тест-векторов конверта:
// два мира проходят один эталон, рассинхрон — красный тест, не тихий
// дрейф эвала от продакшна.
//
// Сравнение после trim: содержимое байт-в-байт, хвостовые переводы
// строк файла не в счёт. {MESSAGE} — плейсхолдер сообщения.
// ============================================================================

struct SophieEvalSyncTests {

    private func etalon(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // → ChappeTests
            .deletingLastPathComponent()   // → ios/Chappe
            .deletingLastPathComponent()   // → ios
            .deletingLastPathComponent()   // → корень репозитория
            .appendingPathComponent("tools/sophie_eval/prompts/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("промпт выбора инструмента совпадает с эталоном эвала")
    func selectionPromptMatchesEtalon() throws {
        let runtime = SophieTools.selectionPrompt(for: "{MESSAGE}")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(runtime == (try etalon("selection_prompt.txt")), Comment(
            rawValue: "изменил промпт в SophieTools — обнови эталон "
            + "tools/sophie_eval/prompts/selection_prompt.txt, иначе эвал "
            + "гоняет НЕ тот промпт, что видит телефон"))
    }

    @Test("схема выбора инструмента совпадает с эталоном эвала")
    func selectionSchemaMatchesEtalon() throws {
        let runtime = SophieTools.selectionSchemaJSON
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(runtime == (try etalon("selection_schema.json")))
    }

    @Test("промпт гейта памяти совпадает с эталоном эвала")
    func gatePromptMatchesEtalon() throws {
        let runtime = SophieRetrievalGate.gatePrompt(for: "{MESSAGE}")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(runtime == (try etalon("gate_prompt.txt")))
    }

    @Test("схема гейта памяти совпадает с эталоном эвала")
    func gateSchemaMatchesEtalon() throws {
        let runtime = SophieRetrievalGate.gateSpec.jsonSchema
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(runtime == (try etalon("gate_schema.json")))
    }

    @Test("шапка промпта консолидации совпадает с эталоном эвала")
    func consolidationHeaderMatchesEtalon() throws {
        // prompt(for: []) — чистая шапка без реплик; реплики Python
        // строит теми же префиксами «Пользователь: »/«Софи: »
        let runtime = SophieConsolidator.prompt(for: [])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(runtime == (try etalon("consolidation_header.txt")))
        let line = SophieConsolidator.prompt(for:
            [SophieMessage(role: .sophie, text: "проверка")])
        #expect(line.hasSuffix("Софи: проверка"),
                "префикс реплик ассистента фиксирован для Python-эвала")
        let schema = SophieConsolidator.spec.jsonSchema
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(schema == (try etalon("consolidation_schema.json")))
    }
}
