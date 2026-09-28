import Foundation

// ============================================================================
// Пунктуатор диктовки (Ф2, бриф 30.07). ДЕТЕРМИНИРОВАННЫЙ КОД, НЕ LLM:
// работает до гейта и без установленной модели — никаких обращений к
// ModelScheduler/LLM здесь быть не должно (проверяется тестом).
//
// Замер на железе 30.07 (docs/reports/punctuation_device.md):
// addsPunctuation для ru-RU — no-op, знаки — наша задача.
//
// Границы предложений — ДВА сигнала сразу (2.1):
//   1) заглавная буква — on-device STT сам ставит её после пауз;
//   2) разрыв во времени между сегментами (timestamp/duration).
// Граница = совпадение обоих. Только заглавная без разрыва — имя
// собственное («Марина», «Андрей»), не граница. Разрыв между
// final-результатами распознавателя — граница всегда (это его же
// детекция паузы). Порог разрыва — в конфиге, калибруется владельцем.
//
// Тип терминала (2.2) — правило Б6 из v1.1: вопросительный стартер →
// «?», иначе точка. Список — PivotMatcher.questionStartersRu (одно
// место, здесь не копируется).
//
// Запятые (2.3) в тексте НЕ расставляются: они — ноль бит и правило
// рендера получателя (RMCodec.commaBefore). Здесь только голосовые
// команды (2.4): «точка», «запятая», «знак вопроса», «новая строка».
// ============================================================================

nonisolated enum Punctuator {

    /// Слово распознавания с таймингом (из SFTranscriptionSegment).
    struct Word: Sendable, Equatable {
        let text: String
        let start: TimeInterval
        let duration: TimeInterval

        var end: TimeInterval { start + duration }
    }

    /// Порог паузы для границы, секунды. В конфиге — владелец
    /// калибрует на живой речи (UserDefaults "dictation.pauseBoundary").
    static var pauseThreshold: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "dictation.pauseBoundary")
        return v > 0 ? v : 0.7
    }

    /// Голосовые команды — показываются человеку (подсказка при первой
    /// диктовке); многословные разбираются по ходу.
    static let voiceCommands: [(spoken: String, mark: String)] = [
        ("точка", "."), ("запятая", ","), ("знак вопроса", "?"),
        ("новая строка", "\n"),
    ]

    static let commandsHint =
        "Голосом можно ставить знаки: «точка», «запятая», «знак вопроса», "
        + "«новая строка»"

    /// Подсказка о командах — один раз, при первой диктовке (2.4).
    /// nil — уже показывали.
    static func commandsHintOnce() -> String? {
        let key = "dictation.commandsHintShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return nil }
        UserDefaults.standard.set(true, forKey: key)
        return commandsHint
    }

    /// Главный вход: финалы распознавания (по одному на кусок речи
    /// между паузами) → текст с терминалами предложений.
    static func punctuate(finals: [[Word]],
                          pauseThreshold: TimeInterval? = nil) -> String {
        let threshold = pauseThreshold ?? Self.pauseThreshold
        // плоский поток слов + границы: между финалами — всегда,
        // внутри финала — заглавная И разрыв
        var tokens: [String] = []
        var boundaryAfter = Set<Int>()   // граница ПОСЛЕ tokens[i]
        for (f, words) in finals.enumerated() {
            for (j, word) in words.enumerated() {
                if j > 0 {
                    let gap = word.start - words[j - 1].end
                    if gap >= threshold, startsCapitalized(word.text) {
                        boundaryAfter.insert(tokens.count - 1)
                    }
                }
                tokens.append(word.text)
            }
            if f < finals.count - 1, !tokens.isEmpty {
                boundaryAfter.insert(tokens.count - 1)
            }
        }
        return render(tokens: tokens, boundaryAfter: boundaryAfter)
    }

    /// Сборка текста: голосовые команды → знаки, терминалы по Б6,
    /// заглавная в начале каждого предложения.
    private static func render(tokens: [String],
                               boundaryAfter: Set<Int>) -> String {
        var sentences: [[String]] = [[]]
        var forcedTerminal: [Int: String] = [:]   // индекс предложения → знак

        var i = 0
        while i < tokens.count {
            let low = tokens[i].lowercased()
            let next = i + 1 < tokens.count ? tokens[i + 1].lowercased() : ""

            // Голосовые команды (2.4)
            if low == "знак", next == "вопроса" {
                forcedTerminal[sentences.count - 1] = "?"
                closeSentence(&sentences)
                i += 2
                continue
            }
            if low == "новая", next == "строка" {
                forcedTerminal[sentences.count - 1] = "\n"
                closeSentence(&sentences)
                i += 2
                continue
            }
            if low == "точка" {
                forcedTerminal[sentences.count - 1] = "."
                closeSentence(&sentences)
                i += 1
                continue
            }
            if low == "запятая" {
                // запятая клеится к предыдущему слову, предложение живёт
                if let last = sentences[sentences.count - 1].last {
                    sentences[sentences.count - 1][
                        sentences[sentences.count - 1].count - 1] = last + ","
                }
                i += 1
                continue
            }

            sentences[sentences.count - 1].append(tokens[i])
            if boundaryAfter.contains(i) {
                closeSentence(&sentences)
            }
            i += 1
        }

        // Терминалы и заглавные
        var parts: [String] = []
        for (s, sentence) in sentences.enumerated() where !sentence.isEmpty {
            var words = sentence
            words[0] = capitalizeFirst(words[0])
            let terminal: String
            if let forced = forcedTerminal[s] {
                terminal = forced
            } else {
                // Б6 (v1.1): вопросительный стартер → «?», иначе точка
                let first = words[0].lowercased()
                terminal = PivotMatcher.questionStartersRu.contains(first)
                    ? "?" : "."
            }
            let body = words.joined(separator: " ")
            parts.append(terminal == "\n" ? body + "\n" : body + terminal)
        }
        return parts.joined(separator: " ")
            .replacingOccurrences(of: "\n ", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func closeSentence(_ sentences: inout [[String]]) {
        if !sentences[sentences.count - 1].isEmpty {
            sentences.append([])
        }
    }

    private static func startsCapitalized(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return first.isUppercase && first.isLetter
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first, first.isLowercase else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
