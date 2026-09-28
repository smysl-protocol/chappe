import Foundation
import UIKit

// ============================================================================
// SophieSummarizer — фоновая свёртка старой истории чата (sophie_presence §1,
// первая настоящая P3-задача планировщика).
//
// Триггер: за пределами окна промпта накопилось >1500 оценочных токенов
// несвёрнутого. Тогда чанками (~1200 токенов на вызов) старое сворачи-
// вается в абзац фактов (промпт prompts/sophie_summary_ru.txt). Курсор
// свёртки хранится рядом с чатом; любой P0–P2 вытесняет генерацию
// мгновенно (LLMError.cancelled) — продолжение с курсора при следующем
// поводе. Политика питания: только на зарядке ИЛИ батарея >30%.
//
// Лимит слов суммария держит КОД (правило №4 CLAUDE.md: длину считает
// код, не модель).
// ============================================================================

actor SophieSummarizer {

    static let shared = SophieSummarizer()

    /// Порог несвёрнутого за окном (оценочные токены).
    static let triggerTokens = 1500
    /// Бюджет истории на один вызов свёртки.
    static let chunkTokens = 1200
    /// Потолок длины суммария в словах — обрезает код.
    static let maxWords = 120

    private let scheduler: ModelScheduler
    private let powerPolicy: @Sendable () async -> Bool
    private var runningKeys = Set<String>()

    /// scheduler и политика питания инжектируются в тестах.
    init(scheduler: ModelScheduler = .shared,
         powerPolicy: @escaping @Sendable () async -> Bool = SophieSummarizer.devicePowerPolicy) {
        self.scheduler = scheduler
        self.powerPolicy = powerPolicy
    }

    /// Только на зарядке ИЛИ батарея >30%. Неизвестный уровень
    /// (симулятор) не блокирует.
    static let devicePowerPolicy: @Sendable () async -> Bool = {
        await MainActor.run {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            switch device.batteryState {
            case .charging, .full: return true
            default:
                let level = device.batteryLevel
                return level < 0 || level > 0.3
            }
        }
    }

    /// Свернуть старое в чате key, если накопилось. Повторный вход по
    /// тому же чату игнорируется; ошибки/вытеснение тихо прерывают —
    /// курсор уже сохранён, продолжим позже.
    func runIfNeeded(key: String) async {
        guard !runningKeys.contains(key) else { return }
        runningKeys.insert(key)
        defer { runningKeys.remove(key) }

        // Триггер проверяется один раз; после срабатывания сворачиваем
        // ВСЁ до начала окна — иначе между суммарием и окном будет дыра.
        guard pendingTokens(key: key) > Self.triggerTokens else { return }

        while await powerPolicy() {
            let messages = SophieChatStore.load(key: key)
            var state = SophieChatStore.loadSummary(key: key)
            let start = windowStart(messages: messages, state: state)
            guard state.cursor < start else { return }   // всё свёрнуто

            // Чанк: целые сообщения до ~chunkTokens
            var chunk: [SophieMessage] = []
            var used = 0
            for message in messages[state.cursor..<start] {
                let cost = SophiePrompt.estimatedTokens(message.text) + 8
                if !chunk.isEmpty, used + cost > Self.chunkTokens { break }
                chunk.append(message)
                used += cost
            }
            guard !chunk.isEmpty else { return }

            do {
                let request = LLMRequest(
                    prompt: Self.userPrompt(existing: state.text, chunk: chunk),
                    systemPrompt: try Self.systemPrompt(),
                    maxTokens: 220,
                    samplingOverride: .extraction)   // temp 0 — факты, не стиль
                // P3: вытесняется любым P0–P2 (sophie_presence §5)
                let response = try await scheduler.withProvider(.background) {
                    try await $0.generate(request)
                }
                state.text = Self.clampWords(
                    response.text.trimmingCharacters(in: .whitespacesAndNewlines))
                state.cursor += chunk.count
                SophieChatStore.saveSummary(state, key: key)
            } catch {
                return   // вытеснили или модель недоступна — курсор цел
            }
        }
    }

    /// Оценочные токены несвёрнутой истории за пределами окна.
    nonisolated func pendingTokens(key: String) -> Int {
        let messages = SophieChatStore.load(key: key)
        let state = SophieChatStore.loadSummary(key: key)
        let start = windowStart(messages: messages, state: state)
        guard state.cursor < start else { return 0 }
        return messages[state.cursor..<start].reduce(0) {
            $0 + SophiePrompt.estimatedTokens($1.text) + 8
        }
    }

    /// Начало окна промпта: окно строится от несвёрнутой части истории.
    private nonisolated func windowStart(messages: [SophieMessage],
                                         state: SophieChatStore.SummaryState) -> Int {
        guard state.cursor <= messages.count else { return messages.count }
        let unsummarized = Array(messages[state.cursor...])
        let window = SophiePrompt.window(unsummarized)
        return messages.count - window.count
    }

    // MARK: Промпт свёртки

    static func systemPrompt() throws -> String {
        let url = Bundle.main.url(forResource: "sophie_summary_ru",
                                  withExtension: "txt", subdirectory: "prompts")
            ?? Bundle.main.url(forResource: "sophie_summary_ru", withExtension: "txt")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw LLMError.generationFailed(
                reason: "prompts/sophie_summary_ru.txt нет в бандле")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func userPrompt(existing: String, chunk: [SophieMessage]) -> String {
        var lines: [String] = []
        lines.append("Прежний суммарий: "
                     + (existing.isEmpty ? "(пусто)" : existing))
        lines.append("Сообщения для свёртки:")
        for message in chunk {
            lines.append((message.role == .user ? "Пользователь: " : "\(AppIdentity.assistantName): ")
                         + message.text)
        }
        lines.append("Суммарий:")
        return lines.joined(separator: "\n")
    }

    /// Жёсткий потолок длины — обрезка кодом, не просьбой к модели.
    static func clampWords(_ text: String, limit: Int = maxWords) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count > limit else { return text }
        return words.prefix(limit).joined(separator: " ") + "…"
    }
}
