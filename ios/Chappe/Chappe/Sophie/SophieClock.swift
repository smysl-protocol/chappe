import Foundation

// ============================================================================
// Часы Софи (Ф6, 30.07.2026). Принцип: МОДЕЛЬ НЕ ПОРОЖДАЕТ ФАКТЫ —
// дата, время и день недели детерминированно приходят из ОС.
//
// Живой баг: на вопрос о времени — верное «08:08, четверг, 30 июля»,
// на вопрос о числе — выдуманное «5 апреля, пятница»; «пятница» для
// четверга дважды, даже после поправок. Календарная арифметика модели
// недоступна — день недели считает Calendar, модель его пересказывает.
//
// Три рубежа:
//  1) nowLine — актуальные дата/время/день недели/пояс в промпт на
//     КАЖДОМ ходе (не при старте сессии);
//  2) directAnswer — перехват ДО модели: вопросы «какое число / какой
//     день недели / сколько времени» отвечает DateFormatter, модель
//     не вызывается вообще (гарантия, не оптимизация);
//  3) validated — пост-валидатор ответа: упомянутые дата/время/день
//     недели сверяются с системными (день недели — с Calendar для
//     УПОМЯНУТОЙ даты), расхождение подменяется, факт — в отладочный
//     лог. Механика та же, что числовой гейт базы знаний.
// ============================================================================

nonisolated enum SophieClock {

    // MARK: Форматирование

    private static func formatter(_ format: String,
                                  timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    private static func gmtLabel(_ timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        let sign = hours >= 0 ? "+" : "-"
        return minutes == 0
            ? "GMT\(sign)\(abs(hours))"
            : String(format: "GMT%@%d:%02d", sign, abs(hours), minutes)
    }

    /// Строка «данных устройства» — добавляется к промпту на каждом
    /// ходе. Идёт в хвосте промпта (рядом с новым сообщением), чтобы
    /// не ломать тёплый префикс KV-кэша.
    static func nowLine(now: Date = Date(),
                        timeZone: TimeZone = .current) -> String {
        let stamp = formatter("EEEE, d MMMM yyyy, HH:mm",
                              timeZone: timeZone).string(from: now)
        return "Данные устройства — единственный источник даты и "
             + "времени: сейчас \(stamp), часовой пояс "
             + "\(gmtLabel(timeZone, at: now))."
    }

    // MARK: Перехват до модели

    /// Нормализация вопроса: регистр, ё→е, пунктуация, пробелы.
    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics
                .union(.whitespaces).inverted)
            .joined()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private static let dateQuestions: Set<String> = [
        "какое сегодня число", "какое число", "какое число сегодня",
        "какая сегодня дата", "какая дата", "дата сегодня",
        "число сегодня", "какое сегодня число и месяц",
        "скажи какое сегодня число", "какая дата сегодня",
    ]
    private static let weekdayQuestions: Set<String> = [
        "какой сегодня день", "какой сегодня день недели",
        "какой день недели", "какой день недели сегодня",
        "день недели", "какой сейчас день недели",
        "скажи какой сегодня день недели", "какой сегодня день скажи",
    ]
    private static let timeQuestions: Set<String> = [
        "сколько времени", "сколько сейчас времени",
        "сколько времени сейчас", "который час", "который сейчас час",
        "сколько время", "скажи сколько времени", "время сейчас",
        "сколько сейчас время",
    ]

    /// Вопрос целиком о дате/времени/дне недели → ответ кодом,
    /// модель не вызывается. Перехват только ТОЧНЫХ коротких вопросов:
    /// «сколько времени идти до Убуда» — не перехватывается, это
    /// вопрос модели (с инструментом), не часам.
    static func directAnswer(for text: String,
                             now: Date = Date(),
                             timeZone: TimeZone = .current) -> String? {
        let q = normalized(text)
        guard !q.isEmpty, q.split(separator: " ").count <= 6 else {
            return nil
        }
        if dateQuestions.contains(q) {
            let stamp = formatter("EEEE, d MMMM yyyy",
                                  timeZone: timeZone).string(from: now)
            return "Сегодня \(stamp)."
        }
        if weekdayQuestions.contains(q) {
            let day = formatter("EEEE", timeZone: timeZone).string(from: now)
            return "Сегодня \(day)."
        }
        if timeQuestions.contains(q) {
            let stamp = formatter("HH:mm", timeZone: timeZone).string(from: now)
            return "Сейчас \(stamp) (часовой пояс "
                 + "\(gmtLabel(timeZone, at: now)))."
        }
        return nil
    }

    // MARK: Пост-валидатор

    struct GateOutcome: Equatable {
        var text: String
        var mismatches: [String]
    }

    private static let monthsGenitive = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]

    /// Именительный и винительный падежи дней недели (для замены в
    /// той же форме: «в пятницу» → «в четверг», «среда» → «четверг»).
    private static let weekdayNominative = [
        "понедельник", "вторник", "среда", "четверг",
        "пятница", "суббота", "воскресенье",
    ]
    private static let weekdayAccusative = [
        "понедельник", "вторник", "среду", "четверг",
        "пятницу", "субботу", "воскресенье",
    ]

    /// Индекс дня недели 0=понедельник…6=воскресенье для даты.
    private static func weekdayIndex(of date: Date,
                                     timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Calendar: 1=воскресенье…7=суббота → 0=пн…6=вс
        return (calendar.component(.weekday, from: date) + 5) % 7
    }

    /// Найденное в тексте упоминание дня недели.
    private struct WeekdayMention {
        let range: Range<String.Index>
        let index: Int          // 0=пн…6=вс
        let accusative: Bool    // «пятницу» ≠ «пятница»
    }

    private static func weekdayMentions(in text: String) -> [WeekdayMention] {
        let lower = text.lowercased()
        var result: [WeekdayMention] = []
        for (index, forms) in zip(weekdayNominative, weekdayAccusative)
            .enumerated() {
            for (form, accusative) in [(forms.0, false), (forms.1, true)]
            where forms.0 != forms.1 || !accusative {
                var search = lower.startIndex
                while let r = lower.range(of: form, range: search..<lower.endIndex) {
                    search = r.upperBound
                    // не подстрока другого слова («средах» и т.п.)
                    let before = r.lowerBound == lower.startIndex ? " "
                        : String(lower[lower.index(before: r.lowerBound)])
                    let after = r.upperBound == lower.endIndex ? " "
                        : String(lower[r.upperBound])
                    let letters = CharacterSet(charactersIn: "абвгдежзийклмнопрстуфхцчшщъыьэюя")
                    guard before.rangeOfCharacter(from: letters) == nil,
                          after.rangeOfCharacter(from: letters) == nil else {
                        continue
                    }
                    result.append(WeekdayMention(range: r, index: index,
                                                 accusative: accusative))
                }
            }
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Упомянутая дата «d месяца [года]».
    private struct DateMention {
        let range: Range<String.Index>
        let day: Int
        let month: Int
        let year: Int?
    }

    private static func dateMentions(in text: String,
                                     regex: NSRegularExpression) -> [DateMention] {
        let ns = text as NSString
        return regex.matches(in: text,
                             range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                guard let whole = Range(m.range, in: text),
                      let day = Int(ns.substring(with: m.range(at: 1))),
                      (1...31).contains(day) else { return nil }
                let monthWord = ns.substring(with: m.range(at: 2)).lowercased()
                guard let month = monthsGenitive.firstIndex(of: monthWord)
                else { return nil }
                var year: Int?
                if m.range(at: 4).location != NSNotFound {
                    year = Int(ns.substring(with: m.range(at: 4)))
                }
                return DateMention(range: whole, day: day,
                                   month: month + 1, year: year)
            }
    }

    private static let dateRegex = try! NSRegularExpression(
        pattern: "(\\d{1,2})\\s+(" + monthsGenitive.joined(separator: "|")
            + ")(\\s+(\\d{4}))?",
        options: [.caseInsensitive])

    private static let timeRegex = try! NSRegularExpression(
        pattern: "(?<![\\d:])([01]?\\d|2[0-3]):([0-5]\\d)(?![\\d:])")

    /// Границы предложения вокруг позиции (для «рядом» = в одном
    /// предложении).
    private static func sentenceRange(around range: Range<String.Index>,
                                      in text: String) -> Range<String.Index> {
        let terminators = CharacterSet(charactersIn: ".!?\n")
        var start = text.startIndex
        var end = text.endIndex
        if let r = text.rangeOfCharacter(from: terminators, options: .backwards,
                                         range: text.startIndex..<range.lowerBound) {
            start = r.upperBound
        }
        if let r = text.rangeOfCharacter(from: terminators,
                                         range: range.upperBound..<text.endIndex) {
            end = r.lowerBound
        }
        return start..<end
    }

    /// Пост-валидатор: сверяет упомянутые день недели / «сегодня»-дату /
    /// «сейчас»-время с системными. Расхождение → подмена правильным
    /// значением, факт — в список mismatches (наружу — в отладочный лог).
    ///
    /// Осторожность: исторические даты без дня недели рядом («в марте
    /// 1791 года») не трогаются; день недели сверяется с Calendar для
    /// УПОМЯНУТОЙ даты (год из текста или текущий).
    static func validated(_ reply: String,
                          now: Date = Date(),
                          timeZone: TimeZone = .current) -> GateOutcome {
        var text = reply
        var mismatches: [String] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentYear = calendar.component(.year, from: now)

        // 1. День недели рядом с датой — считается для ЭТОЙ даты.
        //    Правки с конца, чтобы не сдвигать ранние диапазоны.
        var weekdayFixes: [(Range<String.Index>, String, String)] = []
        for mention in weekdayMentions(in: text) {
            let sentence = sentenceRange(around: mention.range, in: text)
            let dates = dateMentions(in: String(text[sentence]),
                                     regex: dateRegex)
            let correctIndex: Int
            if let date = dates.first {
                var comps = DateComponents()
                comps.year = date.year ?? currentYear
                comps.month = date.month
                comps.day = date.day
                comps.hour = 12
                guard let mentioned = calendar.date(from: comps) else { continue }
                correctIndex = weekdayIndex(of: mentioned, timeZone: timeZone)
            } else if text[sentence].lowercased().contains("сегодня")
                        || text[sentence].lowercased().contains("сейчас") {
                correctIndex = weekdayIndex(of: now, timeZone: timeZone)
            } else {
                continue   // день недели без даты и без «сегодня» не трогаем
            }
            if mention.index != correctIndex {
                let replacement = mention.accusative
                    ? weekdayAccusative[correctIndex]
                    : weekdayNominative[correctIndex]
                weekdayFixes.append((mention.range,
                                     String(text[mention.range]), replacement))
            }
        }
        for (range, wrong, correct) in weekdayFixes.reversed() {
            text.replaceSubrange(range, with: correct)
            mismatches.append("день недели: «\(wrong)» → «\(correct)»")
        }

        // 2. «Сегодня» + дата, не совпадающая с сегодняшней, → подмена.
        let today = calendar.dateComponents([.day, .month, .year], from: now)
        var dateFixes: [(Range<String.Index>, String, String)] = []
        for date in dateMentions(in: text, regex: dateRegex) {
            let sentence = sentenceRange(around: date.range, in: text)
            // только утверждения о «сегодня», и дата недалеко от него
            let sentenceText = text[sentence].lowercased()
            guard let todayPos = sentenceText.range(of: "сегодня") else { continue }
            let gap = text.distance(
                from: sentence.lowerBound, to: date.range.lowerBound)
                - sentenceText.distance(from: sentenceText.startIndex,
                                        to: todayPos.lowerBound)
            guard abs(gap) <= 24 else { continue }   // «сегодня …дата» рядом
            let wrongDay = date.day != today.day
                || date.month != today.month
                || (date.year ?? today.year!) != today.year!
            if wrongDay {
                let stamp = formatter("d MMMM yyyy",
                                      timeZone: timeZone).string(from: now)
                dateFixes.append((date.range,
                                  String(text[date.range]), stamp))
            }
        }
        for (range, wrong, correct) in dateFixes.reversed() {
            text.replaceSubrange(range, with: correct)
            mismatches.append("дата: «\(wrong)» → «\(correct)»")
        }

        // 3. «Сейчас» + время: допуск 3 минуты (ответ генерируется
        //    не мгновенно), дальше — подмена.
        let ns = text as NSString
        var timeFixes: [(Range<String.Index>, String, String)] = []
        for m in timeRegex.matches(in: text,
                                   range: NSRange(location: 0, length: ns.length)) {
            guard let whole = Range(m.range, in: text) else { continue }
            let sentence = sentenceRange(around: whole, in: text)
            guard text[sentence].lowercased().contains("сейчас") else { continue }
            let hour = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let minute = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let nowComps = calendar.dateComponents([.hour, .minute], from: now)
            let mentionedMinutes = hour * 60 + minute
            let nowMinutes = (nowComps.hour ?? 0) * 60 + (nowComps.minute ?? 0)
            if abs(mentionedMinutes - nowMinutes) > 3 {
                let stamp = formatter("HH:mm", timeZone: timeZone)
                    .string(from: now)
                timeFixes.append((whole, String(text[whole]), stamp))
            }
        }
        for (range, wrong, correct) in timeFixes.reversed() {
            text.replaceSubrange(range, with: correct)
            mismatches.append("время: «\(wrong)» → «\(correct)»")
        }

        return GateOutcome(text: text, mismatches: mismatches)
    }

    // MARK: Отладочный лог расхождений

    /// Факт подмены — в Documents/date_gate_log.txt (File Sharing —
    /// забирается с Мака, как бенчи) и в консоль.
    static func logMismatches(_ mismatches: [String], context: String) {
        guard !mismatches.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(context): "
            + mismatches.joined(separator: "; ") + "\n"
        print("[date-gate] \(line)", terminator: "")
        if let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent("date_gate_log.txt")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url, options: .atomic)
            }
        }
    }
}
