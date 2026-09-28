import Foundation

// ============================================================================
// STTNormalizer — правка времён в распознанном тексте ДО конвейера (П5).
//
// Полевой кейс: «ждём уже два часа» STT превратил в «02:00» —
// длительность стала временем суток. Правила:
//  - составное время СОБИРАЕТСЯ только при маркерах часа (в/к/до/около
//    + час [+ минуты]): «в семь тридцать» → «в 07:30», «в 7 30» → «в 07:30»;
//  - Ч:ММ от STT в контексте длительности (уже N / ждём N / N подряд)
//    РАЗБИРАЕТСЯ обратно: «уже 02:00» → «уже 2 часа»;
//  - всё остальное («через 40 минут») не трогается.
// ============================================================================

nonisolated enum STTNormalizer {

    static let hourWords: [String: Int] = [
        "один": 1, "час": 1, "два": 2, "две": 2, "три": 3, "четыре": 4,
        "пять": 5, "шесть": 6, "семь": 7, "восемь": 8, "девять": 9,
        "десять": 10, "одиннадцать": 11, "двенадцать": 12,
    ]
    static let minuteWords: [String: Int] = [
        "пять": 5, "десять": 10, "пятнадцать": 15, "двадцать": 20,
        "тридцать": 30, "сорок": 40, "пятьдесят": 50,
    ]
    /// Маркеры часа — только после них собираем составное время.
    /// «в два часа» ОБЯЗАНО остаться временем суток (фикстура Ф1.1).
    static let hourMarkers: Set<String> = ["в", "к", "до", "около"]
    /// Маркеры длительности — рядом с ними Ч:ММ это НЕ время суток.
    /// Ф1.1 (бенч на железе 30.07): STT сам превращает «за четыре часа»
    /// в «за 04:00» — предлоги за/через/на/«в течение» + число единиц
    /// времени означают ДЛИТЕЛЬНОСТЬ, разбираем обратно.
    static let durationMarkers: Set<String> = ["уже", "ждём", "ждем",
                                               "ждали", "на", "хватит",
                                               "осталось", "за", "через",
                                               "течение"]

    static func normalizeTimes(_ text: String) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let low = tokens[i].lowercased()

            // Разборка: маркер длительности + Ч:ММ → обратно в единицы.
            // «за 04:00» → «за 4 часа»; «через 00:40» → «через 40 минут».
            // Пунктуатор (Ф2) работает ДО нормализатора и мог приклеить
            // терминал: «за 04:00.» — знак снимается на время разбора
            // и возвращается после числительного.
            if durationMarkers.contains(low), i + 1 < tokens.count {
                let raw = tokens[i + 1]
                let suffix = raw.last.map { ".,!?".contains($0) ? String($0) : "" } ?? ""
                let core = suffix.isEmpty ? raw : String(raw.dropLast())
                if let (h, m) = parseClock(core), h <= 12 {
                    if m == 0, h > 0 {
                        out.append(tokens[i])
                        // «в течение» требует родительного: «2 часов»
                        let noun = low == "течение"
                            ? (h == 1 ? "часа" : "часов") : hourNoun(h)
                        out.append("\(h) \(noun)\(suffix)")
                        i += 2
                        continue
                    }
                    if h == 0, m > 0 {
                        out.append(tokens[i])
                        out.append("\(m) \(minuteNoun(m))\(suffix)")
                        i += 2
                        continue
                    }
                }
            }
            // Разборка: «Ч:00 подряд» — тоже длительность
            if let (h, m) = parseClock(tokens[i]), m == 0, h <= 12,
               i + 1 < tokens.count,
               tokens[i + 1].lowercased() == "подряд" {
                out.append("\(h) \(hourNoun(h))")
                i += 1
                continue
            }

            // Сборка: (в|к|до|около) + час + минуты → «в 07:30»
            if hourMarkers.contains(low), i + 2 < tokens.count,
               let hour = hourValue(tokens[i + 1]) {
                var minutes: Int?
                var consumed = 1
                let m1 = tokens[i + 2].lowercased()
                if let word = minuteWords[m1] {
                    minutes = word
                    consumed = 2
                    // составные минуты: «двадцать пять», «сорок пять»
                    if (word == 20 || word == 40), i + 3 < tokens.count,
                       tokens[i + 3].lowercased() == "пять" {
                        minutes = word + 5
                        consumed = 3
                    }
                } else if let digits = Int(m1), (0...59).contains(digits),
                          m1.count == 2 || digits >= 10 {
                    minutes = digits
                    consumed = 2
                }
                if let minutes {
                    out.append(tokens[i])
                    out.append(String(format: "%02d:%02d", hour, minutes))
                    i += 1 + consumed
                    continue
                }
            }

            out.append(tokens[i])
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// «07:30» / «7:30» → (7, 30); не часы — nil.
    private static func parseClock(_ token: String) -> (Int, Int)? {
        let parts = token.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    private static func hourValue(_ token: String) -> Int? {
        let low = token.lowercased()
        if let word = hourWords[low] { return word }
        if let digits = Int(low), (1...23).contains(digits) { return digits }
        return nil
    }

    static func hourNoun(_ hours: Int) -> String {
        switch hours {
        case 1: "час"
        case 2...4: "часа"
        default: "часов"
        }
    }

    static func minuteNoun(_ minutes: Int) -> String {
        let tail = minutes % 10
        if (11...14).contains(minutes % 100) { return "минут" }
        switch tail {
        case 1: return "минуту"
        case 2...4: return "минуты"
        default: return "минут"
        }
    }
}
