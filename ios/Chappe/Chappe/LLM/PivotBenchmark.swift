import Foundation
import UIKit

// ============================================================================
// PivotBenchmark — фаза 2 плана llama_swift_plan.md: эталонная сверка
// на устройстве.
//
// Гонит 12 диктовок (Resources/dictation_corpus.jsonl — копия из
// tools/semdict/) через активный LLMProvider ТЕМ ЖЕ pivot-промптом, что
// tools/semdict/pipeline.py (перенесён дословно; список protected-кодов
// читается из Resources/rm_dict_core_v0.json — той же копии словаря).
// temperature 0 — расхождения с эталоном llama-server только от билда.
//
// Свои стадии кодека (санитизация, коды, байты) здесь НЕ повторяются:
// сверка пивотов и все следующие стадии делаются на Маке тем же
// pipeline.py. Харнесс отдаёт сырые пивоты + замеры.
// ============================================================================

nonisolated enum PivotBenchmark {

    // Промпт из tools/semdict/pipeline.py (PIVOT_PROMPT_TEMPLATE) — дословно.
    // {codes} подставляется списком protected-кодов словаря, как в main().
    static let promptTemplate = """
    You convert dictated Russian speech (raw speech-to-text: no punctuation, filler words, self-corrections) into ONE line of minimal clean English pivot for a semantic codec.

    HARD RULES:
    1. Output exactly one line, nothing else. No "EN:", no explanations.
    2. Short common English words, all lowercase.
    3. ALL numbers as digits: write 6, not six. Times as digits: "at 6", "at 8 in the evening".
    4. Keep every fact: numbers, times, dates, places, names, quantities, needs. Apply self-corrections ("в пятницу то есть в субботу" -> saturday only). Drop fillers (ну, короче, слушай, эээ, блин) and repeats.
    5. Proper names: NAME:Mark.
    6. Special underscore codes: use ONLY codes from this list, spelled exactly:
    {codes}
    Never invent codes or snake_case words. If no code fits, use plain words.
    7. sos_active ONLY when people are in danger or injured and urgently need help RIGHT NOW. Broken equipment, empty fuel, dead battery, closed road, bad weather, radio checks are NOT sos. sos_cancel ONLY to cancel a previously sent alarm.

    Examples:
    RU: ну я это самое буду минут через десять наверное
    EN: be there soon in 10 minutes
    RU: слушай генератор сломался бензина нет купи литров пять
    EN: the generator is broken no petrol buy 5 liters
    RU: блин телефон почти сел если пропаду выйду на связь в девять
    EN: state_battery_low i will be on the radio at 9
    RU: прием прием как слышно это саша
    EN: radio check can you hear me this is NAME:Sasha
    RU: волны сегодня здоровые лодки не пойдут
    EN: waves are big boats do not go today
    RU: у нас пожар в доме человек без сознания нужны спасатели срочно
    EN: sos_active hazard_fire injury_unconscious need_rescue severity_critical loc_at_home
    """

    struct DictationItem: Decodable {
        let ruDictation: String
        enum CodingKeys: String, CodingKey { case ruDictation = "ru_dictation" }
    }

    struct ItemResult: Codable {
        let ru: String
        let pivotRaw: String
        let prefillMs: Double
        let decodeTokS: Double
        let tokens: Int
        enum CodingKeys: String, CodingKey {
            case ru, pivotRaw = "pivot_raw", prefillMs = "prefill_ms",
                 decodeTokS = "decode_tok_s", tokens
        }
    }

    struct Results: Codable {
        let kind: String                 // "pivot_benchmark" | "throttle"
        let device: String
        let providerKind: String
        let modelFile: String
        let loadMs: Double
        let peakRamMb: Double
        /// Prefill холодного прогрева системного промпта (мс) — база для
        /// сравнения с тёплыми prefill в items. 0 — прогрев не выполнялся.
        var warmupPrefillMs: Double = 0
        let items: [ItemResult]
        enum CodingKeys: String, CodingKey {
            case kind, device, providerKind = "provider_kind",
                 modelFile = "model_file", loadMs = "load_ms",
                 peakRamMb = "peak_ram_mb",
                 warmupPrefillMs = "warmup_prefill_ms", items
        }
    }

    // MARK: Загрузка ресурсов

    static func corpus() throws -> [DictationItem] {
        guard let url = Bundle.main.url(forResource: "dictation_corpus",
                                        withExtension: "jsonl") else {
            throw LLMError.generationFailed(reason: "dictation_corpus.jsonl нет в бандле")
        }
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.isEmpty }
        return try lines.map {
            try JSONDecoder().decode(DictationItem.self, from: Data($0.utf8))
        }
    }

    /// Protected-коды словаря — та же выборка, что в pipeline.py main():
    /// entries с layer == "protected", поле en, сортировка по алфавиту.
    static func protectedCodes() throws -> [String] {
        guard let url = Bundle.main.url(forResource: "rm_dict_core_v0",
                                        withExtension: "json") else {
            throw LLMError.generationFailed(reason: "rm_dict_core_v0.json нет в бандле")
        }
        struct Entry: Decodable { let en: String; let layer: String }
        struct Dict: Decodable { let entries: [Entry] }
        let dict = try JSONDecoder().decode(Dict.self, from: Data(contentsOf: url))
        return dict.entries.filter { $0.layer == "protected" }.map(\.en).sorted()
    }

    static func systemPrompt() throws -> String {
        promptTemplate.replacingOccurrences(of: "{codes}",
                                            with: try protectedCodes().joined(separator: ", "))
    }

    // MARK: Прогон

    /// Гонит все диктовки. progress — номер текущей (для UI).
    static func run(provider: any LLMProvider,
                    loadMs: Double,
                    progress: @MainActor @escaping (Int, Int) -> Void)
    async throws -> Results {
        let items = try corpus()
        let system = try systemPrompt()
        var results: [ItemResult] = []
        var peakRam = MemoryStats.footprintMB()

        // Прогрев KV-кэша (фаза 2): один холодный прогон системного промпта.
        // Все последующие вызовы декодируют только свой хвост (диктовку).
        await progress(0, items.count)
        let warmup = try await provider.generate(LLMRequest(
            prompt: "RU: \nEN:", systemPrompt: system,
            maxTokens: 1, samplingOverride: .extraction))

        for (index, item) in items.enumerated() {
            await progress(index + 1, items.count)
            // Тот же формат вызова, что call_llama() в pipeline.py:
            // system = промпт, user = "RU: <текст>\nEN:", temp 0, max 120.
            let request = LLMRequest(
                prompt: "RU: " + item.ruDictation + "\nEN:",
                systemPrompt: system,
                maxTokens: 120,
                samplingOverride: .extraction)
            let response = try await provider.generate(request)
            // stop=["\n"] сервера здесь заменяет обрезка по первой строке
            let pivot = response.text
                .split(separator: "\n", maxSplits: 1,
                       omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            results.append(ItemResult(ru: item.ruDictation,
                                      pivotRaw: pivot,
                                      prefillMs: response.prefillMillis,
                                      decodeTokS: response.tokensPerSecond,
                                      tokens: response.tokensGenerated))
            peakRam = max(peakRam, MemoryStats.footprintMB())
        }

        let config = LLMModelConfig.loadActive()
        return Results(kind: "pivot_benchmark",
                       device: await deviceDescription(),
                       providerKind: config.providerKind.rawValue,
                       modelFile: config.modelFile,
                       loadMs: loadMs,
                       peakRamMb: peakRam,
                       warmupPrefillMs: warmup.prefillMillis,
                       items: results)
    }

    /// Сохраняет результаты в tmp-файл для share-sheet (AirDrop на Мак).
    static func writeJSON(_ results: Results, name: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys,
                                    .withoutEscapingSlashes]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
        try encoder.encode(results).write(to: url, options: .atomic)
        return url
    }

    @MainActor
    static func deviceDescription() -> String {
        UIDevice.current.model + " " + UIDevice.current.systemName + " "
            + UIDevice.current.systemVersion
    }
}
