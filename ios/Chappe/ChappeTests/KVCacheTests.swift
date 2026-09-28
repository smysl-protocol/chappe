//
//  KVCacheTests.swift
//  RMTests
//
//  Проверка «тёплого контекста» (KV-кэш общего префикса, фаза 2):
//   1) повторный вызов с тем же системным промптом префиллит только хвост —
//      prefill обязан упасть в разы;
//   2) кэш не искажает вывод: тёплый результат равен результату свежего
//      рантайма на том же промпте (жадный сэмплинг — детерминизм).
//
//  Гоняется на смоук-модели Qwen2.5-0.5B из ~/RM/models/ (симулятор = CPU,
//  абсолютные скорости не показательны, показательно СООТНОШЕНИЕ).
//

import Foundation
import Testing
@testable import Chappe

// ВНИМАНИЕ (29.07): models/ в gitignore и в новый git worktree НЕ
// приезжает — тест мгновенно падает через Issue.record («смоук-модель
// не найдена»). При заведении worktree каталог клонируется APFS-клоном,
// см. CLAUDE.md, раздел «Как заводить worktree».
private let smokeModelPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()            // RMTests
    .deletingLastPathComponent()            // RM
    .deletingLastPathComponent()            // ios
    .deletingLastPathComponent()            // корень репозитория
    .appendingPathComponent("models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf").path

struct KVCacheTests {

    @Test func warmPrefixSpeedsUpPrefillAndKeepsOutput() async throws {
        guard FileManager.default.fileExists(atPath: smokeModelPath) else {
            Issue.record("смоук-модель не найдена (docs/llama_swift_plan.md §2а): \(smokeModelPath)")
            return
        }
        let system = try PivotBenchmark.systemPrompt()   // настоящий PIVOT-промпт
        let sampling = SamplingParams.extraction          // temp 0 — детерминизм

        let runtime = try LlamaRuntime(modelPath: smokeModelPath,
                                       contextLength: 2048,
                                       cancelFlag: AtomicFlag())

        // Холодный вызов: полный префилл шаблона + системного промпта
        let cold = try runtime.generate(prompt: "RU: привет где ты\nEN:",
                                        systemPrompt: system,
                                        maxTokens: 12, sampling: sampling)

        // Тёплый вызов с ДРУГОЙ диктовкой: общий префикс уже в KV
        let warm = try runtime.generate(prompt: "RU: купи воды пять бутылок\nEN:",
                                        systemPrompt: system,
                                        maxTokens: 12, sampling: sampling)

        print("KV-кэш: холодный prefill \(Int(cold.prefillMillis)) мс, "
            + "тёплый \(Int(warm.prefillMillis)) мс "
            + "(x\(String(format: "%.1f", cold.prefillMillis / max(warm.prefillMillis, 0.001))))")

        #expect(warm.prefillMillis < cold.prefillMillis * 0.5,
                "тёплый prefill \(warm.prefillMillis) мс должен быть в разы меньше холодного \(cold.prefillMillis) мс")

        // Корректность: свежий рантайм на том же промпте даёт тот же текст
        let fresh = try LlamaRuntime(modelPath: smokeModelPath,
                                     contextLength: 2048,
                                     cancelFlag: AtomicFlag())
        let reference = try fresh.generate(prompt: "RU: купи воды пять бутылок\nEN:",
                                           systemPrompt: system,
                                           maxTokens: 12, sampling: sampling)
        #expect(warm.text == reference.text,
                "тёплый кэш исказил вывод: «\(warm.text)» != «\(reference.text)»")

        // Повтор идентичного промпта — почти нулевой prefill (1 токен)
        let repeated = try runtime.generate(prompt: "RU: купи воды пять бутылок\nEN:",
                                            systemPrompt: system,
                                            maxTokens: 12, sampling: sampling)
        #expect(repeated.text == warm.text)
        print("KV-кэш: повтор того же промпта — prefill \(Int(repeated.prefillMillis)) мс")
    }
}
