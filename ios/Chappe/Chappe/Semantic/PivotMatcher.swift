import Foundation

// ============================================================================
// PivotMatcher — пивот-текст → юниты словаря. Порт units_from_pivot
// (tools/semdict/pipeline.py) + lemma_candidates/phrase_index/match_word
// (coverage_test.py). Детерминирован: эталонные пивоты обязаны давать
// те же последовательности юнитов, что python (matcher_reference.json).
//
// Правила: фразы раньше одиночек (длиннейшее окно), простая лемматизация
// суффиксами + неправильные глаголы, числа → num, name_ → name,
// непокрытые прогоны слов → lit.
// ============================================================================

nonisolated final class PivotMatcher: @unchecked Sendable {

    static let shared: PivotMatcher? = RMCodec.shared.map { PivotMatcher(codec: $0) }

    private let codec: RMCodec
    /// Первая словоформа → [(слова фразы, код)], длинные раньше.
    private var phraseIndex: [String: [(words: [String], code: Int)]] = [:]
    /// Одиночные словоформы (без пробела) → код. Слой grammar исключён —
    /// как в coverage_test.py (служебные слова матчатся как смыслы).
    private var singleByEn: [String: Int] = [:]
    /// Фразы v1.1: первая словоформа → [(слова окна, id)], длинные раньше.
    private var v11Index: [String: [(words: [String], id: Int)]] = [:]

    init(codec: RMCodec) {
        self.codec = codec
        for (code, e) in codec.entries where e.layer != "grammar" {
            let words = e.en.split(separator: " ").map(String.init)
            guard let first = words.first else { continue }
            phraseIndex[first, default: []].append((words, code))
            if words.count == 1 {
                singleByEn[e.en] = code
            }
        }
        for key in phraseIndex.keys {
            phraseIndex[key]?.sort { $0.words.count > $1.words.count }
        }
        for (id, p) in codec.phrases {
            for m in p.match {
                let words = m.split(separator: " ").map(String.init)
                guard let first = words.first else { continue }
                v11Index[first, default: []].append((words, id))
            }
        }
        for key in v11Index.keys {
            v11Index[key]?.sort { $0.words.count > $1.words.count }
        }
    }

    // MARK: Лемматизация (порт lemma_candidates)

    private static let irregular: [String: String] = [
        "ate": "eat", "went": "go", "came": "come", "took": "take",
        "said": "say", "saw": "see", "made": "make", "left": "leave",
        "fell": "fall", "told": "tell", "gave": "give", "bought": "buy",
        "sent": "send", "found": "find", "woke": "wake", "met": "meet",
        "ran": "run", "got": "get", "spoke": "speak", "brought": "bring",
        "thought": "think", "heard": "hear", "held": "hold", "kept": "keep",
        "lost": "lose", "paid": "pay", "slept": "sleep", "stood": "stand",
        "sat": "sit", "drove": "drive", "flew": "fly", "forgot": "forget",
        "knew": "know", "wrote": "write", "broke": "break", "chose": "choose",
        "felt": "feel", "caught": "catch", "taught": "teach", "wore": "wear",
        "given": "give", "taken": "take", "gone": "go", "seen": "see",
        "done": "do", "been": "be", "written": "write", "forgotten": "forget",
        "gotten": "get", "eaten": "eat", "driven": "drive", "flown": "fly",
        "spoken": "speak", "chosen": "choose", "woken": "wake",
    ]
    private static let suffixes = ["'s", "s", "es", "ed", "ing", "er", "est"]

    /// Кандидаты леммы в том же порядке, что python-генератор.
    static func lemmaCandidates(_ w: String) -> [String] {
        var out = [w]
        if let irr = irregular[w] { out.append(irr) }
        for suf in suffixes where w.hasSuffix(suf) && w.count - suf.count >= 3 {
            let stem = String(w.dropLast(suf.count))
            out.append(stem)
            if (suf == "ing" || suf == "ed") && stem.count >= 3 {
                out.append(stem + "e")        // coming -> come, closed -> close
                // удвоенная согласная: robbed -> rob, planned -> plan
                if stem.count >= 2,
                   stem[stem.index(before: stem.endIndex)]
                       == stem[stem.index(stem.endIndex, offsetBy: -2)] {
                    out.append(String(stem.dropLast()))
                }
            }
        }
        if w.hasSuffix("ied") && w.count > 4 {
            out.append(String(w.dropLast(3)) + "y")   // replied -> reply
        }
        if w.hasSuffix("ies") && w.count > 4 {
            out.append(String(w.dropLast(3)) + "y")   // cities -> city
        }
        return out
    }

    private func matchWord(_ w: String, allowProtected: Bool) -> Int? {
        for candidate in Self.lemmaCandidates(w) {
            if let code = singleByEn[candidate] {
                if !allowProtected, codec.entries[code]?.layer == "protected" {
                    continue   // П1: protected из чата недостижим
                }
                return code
            }
        }
        return nil
    }

    // MARK: Токенизация (TOKEN_RE = [a-z_']+|\d+)

    /// Стяжения → развёрнутая форма (синхронно с pipeline.py):
    /// смысл собирается концептом + оператором, кодов стяжений нет.
    static let contractions: [String: String] = [
        "don't": "do not", "doesn't": "does not", "didn't": "did not",
        "can't": "can not", "cannot": "can not", "won't": "will not",
        "isn't": "is not", "aren't": "are not", "wasn't": "was not",
        "weren't": "were not", "haven't": "have not", "hasn't": "has not",
        "hadn't": "had not", "wouldn't": "would not", "couldn't": "could not",
        "shouldn't": "should not", "mustn't": "must not", "ain't": "is not",
        "i'm": "i am", "i'll": "i will", "i've": "i have", "i'd": "i would",
        "you're": "you are", "you'll": "you will", "you've": "you have",
        "we're": "we are", "we'll": "we will", "we've": "we have",
        "they're": "they are", "they'll": "they will", "it's": "it is",
        "that's": "that is", "there's": "there is", "he's": "he is",
        "she's": "she is", "let's": "let us", "what's": "what is",
    ]

    /// Singlish-частицы: модель метит незнакомое как NAME:, частицы
    /// тона — не имена (NUS 06.08). Зеркало python — SINGLISH_PARTICLES.
    static let singlishParticles: Set<String> = [
        "lah", "leh", "lor", "liao", "meh", "hor", "sia", "sian", "wat",
        "oso", "haiz", "walao", "aiyo", "aiya", "hee", "bah", "gah",
    ]

    static func tokenize(_ pivot: String) -> [String] {
        let lowered = pivot.lowercased().replacingOccurrences(of: "name:",
                                                              with: "name_")
        var tokens: [String] = []
        var current = ""
        var currentIsDigit = false
        func flush() {
            guard !current.isEmpty else { return }
            // недо-время «7:2» — по-питоновски два отдельных числа
            if let colon = current.firstIndex(of: ":"),
               current.distance(from: colon, to: current.endIndex) != 3 {
                tokens.append(String(current[current.startIndex..<colon]))
                let after = current[current.index(after: colon)...]
                if !after.isEmpty { tokens.append(String(after)) }
                current = ""
                return
            }
            tokens.append(current)
            current = ""
        }
        let chars = Array(lowered)
        for (index, ch) in chars.enumerated() {
            let isWord = (ch >= "a" && ch <= "z") || ch == "_" || ch == "'"
            let isDigit = ch.isNumber && ch.isASCII
            if isWord {
                if currentIsDigit { flush() }
                currentIsDigit = false
                current.append(ch)
            } else if isDigit {
                if !currentIsDigit { flush() }
                // после «:» ровно две цифры (паритет с \d{1,2}:\d{2})
                if let colon = current.firstIndex(of: ":"),
                   current.distance(from: colon, to: current.endIndex) > 2 {
                    flush()
                }
                currentIsDigit = true
                current.append(ch)
            } else if ch == ":", currentIsDigit, !current.contains(":"),
                      current.count <= 2, index + 1 < chars.count,
                      chars[index + 1].isNumber, chars[index + 1].isASCII {
                current.append(ch)     // время HH:MM цельным токеном
            } else if ch == "%" {
                flush()
                tokens.append("%")     // «20%»: процент раньше терялся
                currentIsDigit = false
            } else if ch == "." || ch == "?" || ch == "!" {
                // границы предложений v1.1 — отдельными токенами
                flush()
                tokens.append(String(ch))
                currentIsDigit = false
            } else {
                flush()
            }
        }
        flush()
        // развёртка стяжений после нарезки: "don't" — один токен
        return tokens.flatMap { token in
            Self.contractions[token].map { $0.split(separator: " ").map(String.init) }
                ?? [token]
        }
    }

    /// П4: подряд повторяющиеся n-граммы (n≤4) свыше двух — след
    /// зацикливания модели, не речь; остаётся одна копия.
    static func collapseRepeats(_ units: [RMCodec.Unit]) -> [RMCodec.Unit] {
        var out = units
        for n in stride(from: 4, through: 1, by: -1) {
            var i = 0
            var result: [RMCodec.Unit] = []
            while i < out.count {
                guard i + n <= out.count else {
                    result.append(out[i]); i += 1; continue
                }
                let gram = Array(out[i..<i + n])
                var k = 1
                while i + (k + 1) * n <= out.count,
                      Array(out[(i + k * n)..<(i + (k + 1) * n)]) == gram {
                    k += 1
                }
                if k == 1 {
                    result.append(out[i])   // скользящее окно, не прыжок
                    i += 1
                    continue
                }
                result.append(contentsOf: gram)
                if k < 3 {
                    // 2 повтора — легальная речь («очень-очень»)
                    result.append(contentsOf: Array(repeating: gram,
                                                    count: k - 1).flatMap { $0 })
                }
                i += n * k
            }
            out = result
        }
        return out
    }

    /// am/pm после времени: (минуты суток, новый индекс) — порт _meridiem.
    static func meridiem(h: Int, m: Int, toks: [String],
                         i: Int) -> (minutes: Int, next: Int) {
        var h = h, i = i
        if i < toks.count, toks[i] == "am" || toks[i] == "pm" {
            h = h % 12 + (toks[i] == "pm" ? 12 : 0)
            i += 1
        }
        return (h * 60 + m, i)
    }

    /// Б5: идиома кодируется целиком/литералом, НИКОГДА пословно.
    static let idiomsLit: [[String]] = [
        ["turned", "out"], ["turn", "out"], ["turns", "out"],
        ["worked", "out"], ["figure", "out"], ["figured", "out"],
    ]
    /// Б6: вопросительные стартеры — знак меняет смысл.
    static let questionStarters: Set<String> = [
        "how", "what", "where", "when", "why", "who", "did", "do",
        "does", "are", "is", "can", "could", "will", "would", "have",
        "has", "am", "was", "were",
    ]

    /// Б6 для русского ТЕКСТА (пунктуатор Ф2, 30.07): то же правило
    /// «вопросительный стартер → "?"», но до пивота — на транскрипте
    /// диктовки. Единственное место со списком ru-стартеров; пунктуатор
    /// ссылается сюда, не копирует.
    static let questionStartersRu: Set<String> = [
        "где", "куда", "откуда", "когда", "почему", "зачем", "как",
        "кто", "что", "чей", "чья", "чьё", "какой", "какая", "какие",
        "сколько", "ли", "можно", "неужели", "разве",
    ]

    // MARK: Порт units_from_pivot

    /// allowProtected: false — чат-контекст (П1): protected-диапазон
    /// запрещён, такие слова уходят обычными кодами или литералами.
    /// true — SOS-путь и эталонные сверки (поведение как раньше).
    func units(fromPivot pivot: String,
               allowProtected: Bool = true) -> [RMCodec.Unit] {
        // эмодзи — отдельными юнитами до токенизации (синхронно с
        // pipeline.py): из таблицы — emoji, вне — литерал; хвостом
        var emojiUnits: [RMCodec.Unit] = []
        var buffer = ""
        func flushEmoji() {
            guard !buffer.isEmpty else { return }
            emojiUnits.append(codec.emojiIndex[buffer] != nil
                              ? .emoji(buffer) : .lit(buffer))
            buffer = ""
        }
        for scalar in pivot.unicodeScalars {
            let v = scalar.value
            let isEmojiBase = (0x2600...0x27BF).contains(v)
                || (0x2B00...0x2BFF).contains(v)
                || (0x1F000...0x1FAFF).contains(v)
            let isJoiner = v == 0x200D || v == 0xFE0F
                || (0x1F3FB...0x1F3FF).contains(v)
            if isEmojiBase {
                if !buffer.isEmpty,
                   buffer.unicodeScalars.last?.value != 0x200D {
                    // база после базы без ZWJ — новая последовательность
                    flushEmoji()
                }
                buffer.unicodeScalars.append(scalar)
            } else if isJoiner && !buffer.isEmpty {
                buffer.unicodeScalars.append(scalar)
            } else {
                flushEmoji()
            }
        }
        flushEmoji()
        let toks = Self.tokenize(pivot)
        var units: [RMCodec.Unit] = []
        var residualRun: [String] = []
        var i = 0

        func flushResidual() {
            if !residualRun.isEmpty {
                units.append(.lit(residualRun.joined(separator: " ")))
                residualRun = []
            }
        }

        while i < toks.count {
            let t = toks[i]
            if t.hasPrefix("name_") {
                let raw = String(t.dropFirst(5))
                // Singlish-частицы — не имена (NUS-замер 06.08:
                // liao→name_Liao давал Имя с заглавной в рендере).
                // Понижаем до слова — уйдёт литералом. Зеркало
                // python — pipeline.sanitize_pivot.
                if Self.singlishParticles.contains(raw.lowercased()) {
                    residualRun.append(raw.lowercased())
                    i += 1
                    continue
                }
                flushResidual()
                units.append(.name(raw.prefix(1).uppercased()
                                   + raw.dropFirst().lowercased()))
                i += 1
                continue
            }
            if t.contains(":"), t.replacingOccurrences(of: ":", with: "")
                .allSatisfy({ $0.isNumber && $0.isASCII }) {
                // токен HH:MM → время суток; следом am/pm — учесть
                flushResidual()
                let parts = t.split(separator: ":")
                let h = Int(parts[0]) ?? 0, m = Int(parts[1]) ?? 0
                if h < 24, m < 60 {
                    let (minutes, next) = Self.meridiem(h: h, m: m,
                                                        toks: toks, i: i + 1)
                    units.append(.time(minutes))
                    i = next
                    continue
                }
                units.append(.num(Int(t.replacingOccurrences(of: ":",
                                                             with: "")) ?? 0))
                i += 1
                continue
            }
            if t == "." || t == "?" || t == "!" {
                flushResidual()
                let boundary = t == "." ? "sent_end"
                    : t == "?" ? "sent_question" : "sent_exclaim"
                // границы живут в grammar-слое — singleByEn его
                // исключает, берём из полного индекса словаря
                if let code = codec.byEn[boundary] {
                    units.append(.code(code))
                }
                i += 1
                continue
            }
            if t == "%" {
                // «20%» → число + код percent (раньше % терялся)
                flushResidual()
                if let code = singleByEn["percent"] {
                    units.append(.code(code))
                }
                i += 1
                continue
            }
            if !t.isEmpty, t.allSatisfy({ $0.isNumber && $0.isASCII }) {
                flushResidual()
                // Б4: «100 percent»/«1000 times» — усилитель, НЕ величина
                // (измеримый контекст оставляет число числом)
                let nxt = i + 1 < toks.count ? toks[i + 1] : ""
                let window = Set(toks[max(0, i - 2)..<min(toks.count, i + 3)])
                let measurable: Set<String> = ["battery", "charge", "level",
                                               "humidity", "capacity", "score"]
                if (Int(t) == 100 && nxt == "percent"
                        || Int(t) == 1000 && (nxt == "times" || nxt == "time")),
                   window.isDisjoint(with: measurable),
                   let emphasis = codec.byEn["op_emphasis"] {
                    units.append(.code(emphasis))
                    i += 2
                    continue
                }
                // «число + валюта» → сумма (esc_amount); слов валют
                // в словаре нет — путь кодирования один
                if i + 1 < toks.count,
                   let iso = RMCodec.currencyWords[toks[i + 1]] {
                    units.append(.amount(Int(t) ?? 0, iso))
                    i += 2
                    continue
                }
                // «720 am» / «7 pm» (модель пишет время числом)
                if i + 1 < toks.count,
                   toks[i + 1] == "am" || toks[i + 1] == "pm",
                   let n = Int(t) {
                    if n <= 12 {
                        let (minutes, next) = Self.meridiem(h: n, m: 0,
                                                            toks: toks, i: i + 1)
                        units.append(.time(minutes))
                        i = next
                        continue
                    }
                    if n >= 100, n <= 1259, n % 100 < 60 {
                        let (minutes, next) = Self.meridiem(h: n / 100,
                                                            m: n % 100,
                                                            toks: toks, i: i + 1)
                        units.append(.time(minutes))
                        i = next
                        continue
                    }
                }
                // «0720»: ведущий ноль в 3-4 цифрах — однозначно время
                if t.hasPrefix("0"), t.count == 3 || t.count == 4,
                   let n = Int(t), n / 100 < 24, n % 100 < 60 {
                    let (minutes, next) = Self.meridiem(h: n / 100,
                                                        m: n % 100,
                                                        toks: toks, i: i + 1)
                    units.append(.time(minutes))
                    i = next
                    continue
                }
                units.append(.num(Int(t) ?? 0))
                i += 1
                continue
            }
            // Б5: идиома → литерал целиком (если не словарная фраза)
            if let idiom = Self.idiomsLit.first(where: { w in
                i + w.count <= toks.count
                    && Array(toks[i..<i + w.count]) == w
                    && codec.byEn[w.joined(separator: " ")] == nil
            }) {
                flushResidual()
                units.append(.lit(idiom.joined(separator: " ")))
                i += idiom.count
                continue
            }
            // Фразы v1.1: длиннейшее совпадение выигрывает у словарных
            // при БОЛЬШЕЙ длине (равная — словарный код старше)
            var v11Hit: (id: Int, length: Int)?
            outerV11: for first in Self.lemmaCandidates(t) {
                for (words, id) in v11Index[first] ?? [] {
                    let L = words.count
                    guard i + L <= toks.count else { continue }
                    let window = Array(toks[i..<i + L])
                    let allMatch = (0..<L).allSatisfy { j in
                        Self.lemmaCandidates(window[j]).contains(words[j])
                    }
                    if allMatch {
                        v11Hit = (id, L)
                        break outerV11
                    }
                }
            }
            // Фразы раньше одиночек: длиннейшее окно от любой леммы
            var hit: (code: Int, length: Int)?
            outer: for first in Self.lemmaCandidates(t) {
                for (words, code) in phraseIndex[first] ?? [] {
                    if !allowProtected,
                       codec.entries[code]?.layer == "protected" {
                        continue   // П1: protected из чата недостижим
                    }
                    let L = words.count
                    guard L > 1, i + L <= toks.count else { continue }
                    let window = Array(toks[i..<i + L])
                    let allMatch = (0..<L).allSatisfy { j in
                        Self.lemmaCandidates(window[j]).contains(words[j])
                    }
                    if allMatch {
                        hit = (code, L)
                        break outer
                    }
                }
            }
            if let v11Hit, v11Hit.length > (hit?.length ?? 0) {
                flushResidual()
                units.append(.phrase(v11Hit.id))
                i += v11Hit.length
                continue
            }
            if let hit {
                flushResidual()
                units.append(.code(hit.code))
                i += hit.length
                continue
            }
            if let code = matchWord(t, allowProtected: allowProtected) {
                flushResidual()
                units.append(.code(code))
            } else {
                residualRun.append(t)
            }
            i += 1
        }
        flushResidual()
        // П1: в чат-контексте protected не может просочиться ни одним путём
        assert(allowProtected || !units.contains {
            if case .code(let code) = $0 {
                return codec.entries[code]?.layer == "protected"
            }
            return false
        }, "protected-код в чат-контексте — нарушение слоя защиты")
        // П4 (29.07): зацикливание модели — повтор n-граммы юнитов
        // ≥3 раз подряд схлопывается до одной («нуждается в помощи ×4»)
        units = Self.collapseRepeats(units)
        // Б6: вопросительная структура без терминала → граница-вопрос
        func isBoundary(_ u: RMCodec.Unit) -> Bool {
            if case .code(let c) = u,
               let en = codec.entries[c]?.en {
                return en == "sent_end" || en == "sent_question"
                    || en == "sent_exclaim"
            }
            return false
        }
        if let last = units.last, !isBoundary(last),
           let first = toks.first, Self.questionStarters.contains(first),
           toks.count > 1, toks[1] != "not",   // «do not …» — императив
           let q = codec.byEn["sent_question"] {
            units.append(.code(q))
        }
        return units + emojiUnits
    }
}
