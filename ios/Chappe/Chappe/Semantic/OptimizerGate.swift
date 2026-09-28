import Foundation

// ============================================================================
// Гейт оптимизатора текста (часть 2 брифа 08.08).
//
// Оптимизатор переписывает то, что НАПИСАЛ ЧЕЛОВЕК, силами модели. Это
// опаснее пивота: там модель переводила смысл в коды и гейты ловили
// добавленное, здесь она меняет авторский текст, и «сохранив смысл»
// теряются отрицание, условие, оттенок.
//
// Непреложное правило №9 проекта: правила в промпте не работают. Поэтому
// защита — КОД: переписанный вариант сверяется с исходным по шести
// классам, и при расхождении оптимизация просто не предлагается (человек
// остаётся со своим текстом). Промпт-подсказки — только снижение частоты.
//
// Классы сверки (те же, что у гейта сущностей, плюс приблизительность —
// требование владельца 08.08: в живом корпусе она частая и теряется
// первой):
//   1. отрицание       — «не», «нет», «нельзя», «без», «ни»
//   2. условие         — «если», «когда», «в случае», «иначе»
//   3. числа           — цифры и словесные числительные, как мультимножество
//   4. имена           — @упоминания и слова с заглавной внутри фразы
//   5. время           — часы, «утром/вечером», «завтра», «в 7»
//   6. место           — предложные группы с топонимом (по газетиру)
//   7. приблизительность — «наверно», «примерно», «около», «где-то», «вроде»
//
// Направление проверки НЕсимметрично:
//  - потеря класса — всегда провал (смысл обеднел);
//  - появление отрицания/условия/числа, которого не было, — тоже провал
//    (модель придумала ограничение);
//  - исчезновение вводных слов вежливости провалом НЕ считается — ради
//    этого оптимизатор и нужен.
// ============================================================================

nonisolated enum OptimizerGate {

    /// Причина отказа от переписанного варианта; nil — можно предлагать.
    static func rejectionReason(source: String, rewritten: String) -> String? {
        for check in checks {
            if let reason = check.run(source, rewritten) { return reason }
        }
        return nil
    }

    private struct Check {
        let run: (String, String) -> String?
    }

    private static let checks: [Check] = [
        Check { src, out in
            diffSet(negations(src), negations(out), "отрицание")
        },
        Check { src, out in
            diffSet(conditions(src), conditions(out), "условие")
        },
        Check { src, out in
            diffSet(numbers(src), numbers(out), "число")
        },
        Check { src, out in
            // имена только на потерю: сокращать обращения можно,
            // а вот терять адресата или выдумывать нового — нельзя
            diffSet(names(src), names(out), "имя")
        },
        Check { src, out in
            diffSet(times(src), times(out), "время")
        },
        Check { src, out in
            diffSet(places(src), places(out), "место")
        },
        Check { src, out in
            // приблизительность: «наверно» → уверенное утверждение
            // меняет обещание человека, это не сокращение
            let a = approximations(src), b = approximations(out)
            if !a.isEmpty && b.isEmpty {
                return "оптимизатор: потеряна приблизительность "
                     + "«\(a.sorted().joined(separator: ", "))»"
            }
            return nil
        },
    ]

    /// Общая сверка мультимножеств: потеря и появление одинаково плохи.
    private static func diffSet(_ source: Set<String>, _ rewritten: Set<String>,
                                _ className: String) -> String? {
        let lost = source.subtracting(rewritten)
        if !lost.isEmpty {
            return "оптимизатор: потеряно \(className) "
                 + "«\(lost.sorted().joined(separator: ", "))»"
        }
        let added = rewritten.subtracting(source)
        if !added.isEmpty {
            return "оптимизатор: добавлено \(className) "
                 + "«\(added.sorted().joined(separator: ", "))»"
        }
        return nil
    }

    // MARK: Разбор классов (чистые функции — тестируются напрямую)

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
    }

    static let negationMarkers: Set<String> = [
        "не", "нет", "ни", "нельзя", "без", "никогда", "никто", "ничего",
        "отмена", "отменяется", "отбой",
    ]

    static func negations(_ text: String) -> Set<String> {
        Set(tokens(text).filter { negationMarkers.contains($0) })
    }

    static let conditionMarkers: Set<String> = [
        "если", "когда", "иначе", "случае", "условии", "пока", "разве",
    ]

    static func conditions(_ text: String) -> Set<String> {
        Set(tokens(text).filter { conditionMarkers.contains($0) })
    }

    /// Словесные числительные — те, что реально встречаются в корпусе.
    static let wordNumbers: [String: String] = [
        "ноль": "0", "один": "1", "одна": "1", "два": "2", "две": "2",
        "три": "3", "четыре": "4", "пять": "5", "шесть": "6", "семь": "7",
        "восемь": "8", "девять": "9", "десять": "10", "одиннадцать": "11",
        "двенадцать": "12", "полдень": "12", "полночь": "0",
        "двадцать": "20", "тридцать": "30", "сорок": "40", "пятьдесят": "50",
        "сто": "100", "тысяча": "1000", "пара": "2", "пару": "2",
    ]

    /// Стемы числительных под падежи: «тысяч», «тысячи», «сотен», «пары».
    static let wordNumberStems: [String: String] = [
        "тысяч": "1000", "сотен": "100", "сотни": "100", "пары": "2",
        "десятк": "10", "двойк": "2", "трой": "3",
    ]

    /// Числа как мультимножество значений: «7» и «семь» — одно и то же,
    /// иначе гейт ругался бы на честную нормализацию.
    ///
    /// Часы из класса чисел ИСКЛЮЧЕНЫ: «6:30» — это время, им занимается
    /// свой класс. Иначе потеря времени докладывалась бы как «потеряно
    /// число 6, 30» — правда, но не та, которую нужно показать человеку.
    static func numbers(_ text: String) -> Set<String> {
        var out = Set<String>()
        var stripped = text
        for range in text.ranges(ofPattern: "\\d{1,2}[:.]\\d{2}").reversed() {
            stripped.replaceSubrange(range, with: " ")
        }
        for token in tokens(stripped) {
            if token.allSatisfy({ $0.isNumber }), !token.isEmpty {
                out.insert(String(Int(token) ?? 0))
            } else if let value = wordNumbers[token] {
                out.insert(value)
            } else if let stemmed = wordNumberStems.first(where: {
                token.hasPrefix($0.key)
            }) {
                // падежи: «тысяч», «тысячи», «сотен», «пары»
                out.insert(stemmed.value)
            } else if token.contains("-"), token.first?.isNumber == true {
                // диапазоны «7-8» — оба конца
                for part in token.split(separator: "-")
                where part.allSatisfy({ $0.isNumber }) {
                    out.insert(String(Int(part) ?? 0))
                }
            }
        }
        return out
    }

    /// Имена: @упоминания и слова с заглавной не в начале предложения.
    static func names(_ text: String) -> Set<String> {
        var out = Set<String>()
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        var sentenceStart = true
        for word in words {
            let clean = word.trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted.subtracting(
                    CharacterSet(charactersIn: "@")))
            defer {
                sentenceStart = word.hasSuffix(".") || word.hasSuffix("!")
                    || word.hasSuffix("?")
            }
            guard let first = clean.first else { continue }
            if first == "@" {
                out.insert(clean.lowercased())
            } else if first.isUppercase, !sentenceStart, clean.count > 2 {
                out.insert(clean.lowercased())
            }
        }
        return out
    }

    static let timeMarkers: Set<String> = [
        "утром", "утра", "днём", "днем", "дня", "вечером", "вечера",
        "ночью", "ночи", "завтра", "сегодня", "послезавтра", "вчера",
        "сейчас", "потом", "часов", "часа", "час", "минут", "минуты",
    ]

    static func times(_ text: String) -> Set<String> {
        var out = Set(tokens(text).filter { timeMarkers.contains($0) })
        // «в 7:30» и «в 7» — время, а не просто число
        for match in text.ranges(ofPattern: "\\d{1,2}[:.]\\d{2}") {
            out.insert(String(text[match]).replacingOccurrences(of: ".",
                                                                with: ":"))
        }
        return out
    }

    /// Место. Топонимы с заглавной ловит класс имён; здесь — бытовые
    /// слова-места строчными. Список не выдуман: взят по частотности из
    /// живого корпуса (полевого корпуса (приватен, см. publication manifest)),
    /// сравнение по стему — падежи не должны считаться потерей.
    static let placeStems: [String] = [
        "пляж", "аэропорт", "остров", "отел", "вилл", "кафе", "ресторан",
        "магазин", "рынок", "рынк", "мост", "водопад", "храм", "причал",
        "заправк", "больниц", "аптек", "стоянк", "парковк", "улиц",
        "дорог", "деревн", "город",
    ]

    static func places(_ text: String) -> Set<String> {
        var out = Set<String>()
        for token in tokens(text) {
            for stem in placeStems where token.hasPrefix(stem) {
                out.insert(stem)
                break
            }
        }
        return out
    }

    static let approximationMarkers: Set<String> = [
        "наверно", "наверное", "примерно", "около", "порядка", "вроде",
        "приблизительно", "кажется", "где-то", "почти", "чуть",
        "возможно", "может", "似", "типа",
    ]

    static func approximations(_ text: String) -> Set<String> {
        Set(tokens(text).filter { approximationMarkers.contains($0) })
    }
}

private extension String {
    /// Диапазоны совпадений регулярного выражения (без внешних зависимостей).
    func ranges(ofPattern pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let full = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: full).compactMap {
            Range($0.range, in: self)
        }
    }
}
