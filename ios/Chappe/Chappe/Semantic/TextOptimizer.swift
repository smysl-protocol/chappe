import Foundation

// ============================================================================
// Оптимизатор текста (часть 2 брифа 08.08): «как сказал» → «как короче».
//
// Что делает: просит модель переписать текст компактнее СЛОВАМИ ИЗ
// СЛОВАРЯ Smysl — чтобы сообщение уложилось в меньшее число пакетов.
// Результат подставляется прямо в поле ввода; человек видит его до
// отправки и может вернуть свой вариант.
//
// Безопасность — не в промпте, а в коде (непреложное №9): что бы модель
// ни вернула, результат проходит OptimizerGate по семи классам смысла
// (отрицание, условие, число, имя, время, место, приблизительность).
// Не прошёл — оптимизация просто не предлагается, текст человека цел.
//
// Выигрыш показывается ТОЛЬКО в пакетах и только когда их число реально
// уменьшилось (требование владельца 08.08): экономия байтов внутри
// одного пакета человеку ничего не даёт и читалась бы как шум.
// ============================================================================

nonisolated enum TextOptimizer {

    /// Итог попытки. `rejected` — гейт отверг: показывать нечего,
    /// но причину полезно записать в отладку.
    enum Outcome {
        case optimized(text: String, packetsBefore: Int, packetsAfter: Int)
        case noGain          // короче не стало (или пакетов столько же)
        case rejected(String)
        case unavailable     // модель недоступна
    }

    static let enabledKey = "optimizer.enabled"

    /// По умолчанию — предлагать (решение владельца).
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Стоит ли вообще показывать иконку: есть непокрытые словарём слова.
    /// Текст, покрытый целиком, оптимизировать нечем — иконку не
    /// показываем, иначе человек нажмёт, ничего не изменится и решит,
    /// что сломано.
    static func worthOffering(_ text: String) -> Bool {
        guard isEnabled else { return false }
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "-" })
            .map(String.init)
            .filter { $0.count > 2 }
        guard words.count >= 3 else { return false }   // «ок», «еду» — нечего
        return words.contains { !SemanticEncoder.lexiconCovers($0) }
    }

    /// Сколько пакетов займёт текст на проводе.
    static func packets(for text: String) -> Int {
        (try? TextEncoder.encode(msgID: 0, text: text,
                                 wantAck: true).count) ?? 1
    }

    static let systemPrompt = """
        You shorten Russian chat messages for a very narrow radio channel.
        Rewrite the message using simpler, more common Russian words, \
        keeping EVERY fact. Rules you must never break:
        - keep all negations («не», «нет», «нельзя») exactly as they are;
        - keep all conditions («если», «когда») as conditions;
        - keep every number, name, time and place unchanged;
        - keep hedging words («наверно», «примерно», «около») — do not turn \
        a guess into a statement;
        - drop only politeness, filler and repetition.
        Answer with the rewritten message and nothing else.
        """

    /// Переписать текст. Промпт — подсказка, гейт — гарантия.
    static func optimize(_ text: String) async -> Outcome {
        let before = packets(for: text)
        let request = LLMRequest(prompt: text, systemPrompt: systemPrompt,
                                 maxTokens: 220)
        let response: LLMResponse
        do {
            response = try await ModelScheduler.shared
                .withProvider(.interactive) { provider in
                    try await provider.generateStreaming(request) { _ in }
                }
        } catch {
            return .unavailable
        }
        let rewritten = response.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'"))
        guard !rewritten.isEmpty, rewritten != text else { return .noGain }

        if let reason = OptimizerGate.rejectionReason(source: text,
                                                      rewritten: rewritten) {
            DictationDebugLog.stage("оптимизатор отвергнут: \(reason)")
            return .rejected(reason)
        }
        let after = packets(for: rewritten)
        guard after < before else { return .noGain }
        OptimizerStats.record(source: text, rewritten: rewritten)
        return .optimized(text: rewritten, packetsBefore: before,
                          packetsAfter: after)
    }
}
