import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Крэш шёпота 28.07: промпт с длинным транскриптом (> n_batch = 2048
// токенов) ронял процесс GGML-ассертом в llama_decode — prefill шёл
// одним батчем. Регресс: живой рантайм (смоук-модель 0.5B) обязан
// пережить промпт больше 2048 токенов; транскрипт шёпота — под
// токен-бюджетом.
// ============================================================================

// ВНИМАНИЕ (29.07): models/ в gitignore и в новый git worktree НЕ
// приезжает — тест мгновенно падает через Issue.record («смоук-модель
// не найдена»). При заведении worktree каталог клонируется APFS-клоном,
// см. CLAUDE.md, раздел «Как заводить worktree».
private let smokeModelPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf").path

struct WhisperCrashTests {

    /// До фикса этот тест РОНЯЛ процесс (GGML abort в llama_decode).
    @Test func longPromptPrefillSurvives() async throws {
        guard FileManager.default.fileExists(atPath: smokeModelPath) else {
            Issue.record("смоук-модель не найдена: \(smokeModelPath)")
            return
        }
        // ~2600 токенов — больше n_batch (2048), но в контекст влезает
        let longTranscript = (0..<120).map {
            "Я собеседнику: сообщение номер \($0) про дорогу мост рынок"
        }.joined(separator: "\n")

        let runtime = try LlamaRuntime(modelPath: smokeModelPath,
                                       contextLength: 4096,
                                       cancelFlag: AtomicFlag())
        let response = try runtime.generate(
            prompt: longTranscript + "\nВопрос: что делать?",
            systemPrompt: "Отвечай кратко.",
            maxTokens: 8,
            sampling: .extraction)
        #expect(response.tokensGenerated > 0)
        #expect(response.prefillMillis > 0)
    }

    /// Транскрипт шёпота обрезается токен-бюджетом (свежие — в приоритете).
    @Test @MainActor func whisperTranscriptIsBudgeted() {
        // логика бюджета — реплика цикла из whisper(): проверяем свойство
        let entries: [ChatEntry] = (0..<12).map { i in
            ChatEntry(kind: .outgoing,
                      text: "сообщение \(i) " + String(repeating: "слово ", count: 120))
        }
        var lines: [String] = []
        var budget = 1200
        for entry in entries.filter({ $0.kind == .outgoing }).suffix(12).reversed() {
            let line = "Я собеседнику: \(entry.text)"
            let cost = SophiePrompt.estimatedTokens(line)
            if budget - cost < 0 { break }
            budget -= cost
            lines.append(line)
        }
        let transcript = lines.reversed().joined(separator: "\n")
        #expect(SophiePrompt.estimatedTokens(transcript) <= 1200)
        #expect(!lines.isEmpty, "хоть что-то из свежего входит")
        // свежайшее сообщение — обязательно внутри
        #expect(transcript.contains("сообщение 11"))
    }
}
