import Foundation

// ============================================================================
// SemanticEncoder — боевая цепочка сжатия (фаза C):
// текст RU → модель (PIVOT-промпт из бенчмарка) → санитайзер (порт
// sanitize_pivot из pipeline.py) → матчер → кодек → байты.
//
// Вызов модели — P1 в планировщике (человек ждёт отправки).
// Модель недоступна → nil: вызывающий честно откатывается на
// envelope TEXT без сжатия.
// ============================================================================

nonisolated enum SemanticEncoder {

    struct Encoded: Sendable {
        let pivotRaw: String       // как ответила модель
        let pivot: String          // после санитайзера
        let units: [RMCodec.Unit]
        let blob: [UInt8]          // байты кодека
        // Текст для поля/ленты: развёртка кодов; после смысловой петли —
        // сверенный Каей русский (машинную развёртку словарь даёт беднее)
        var rendered: String
        // Замеры конвейера (фаза 1: отчёт по длинным диктовкам)
        var chunkCount: Int = 1
        var pivotMillis: Double = 0
        /// Текст после смысловой петли (nil — петля не гонялась
        /// или не улучшила). Для отладки и бенчей.
        var loopRewritten: String? = nil
    }

    /// Итог подготовки: семантика ИЛИ текст. needsCard — показать честную
    /// карточку «сжатие не подходит» (пред-детект/gate); false — тихий
    /// откат (модель недоступна — как раньше).
    enum Outcome: Sendable {
        case semantic(Encoded)
        case text(reason: String, needsCard: Bool)
    }

    /// Полная цепочка: пред-детект (без модели) → проход конвейера →
    /// смысловая петля (сравнение исходника с развёрнутым результатом,
    /// максимум один круг) → финал.
    static func prepare(russian text: String,
                        pauseSegments: [String] = []) async -> Outcome {
        // П3: короткие фразы (≤4 слов) всегда текстом, дословно —
        // искажение («дальше медленно» → «идти медленно») дороже
        // экономии, текстом это копейки. Проверка ДО модели и словаря.
        if wordCount(text) <= 4 {
            return .text(reason: "короткое — текстом дословно",
                         needsCard: false)
        }

        guard let codec = RMCodec.shared,
              let matcher = PivotMatcher.shared,
              ModelScheduler.isLocalProviderActive() else {
            return .text(reason: "локальная модель недоступна", needsCard: false)
        }

        // Б3 (29.07): «(к HH:MM)» — служебная метка ПРИЁМНИКА; если она
        // попала во вход (эхо, пересказ, цитата) — вычищаем до пивота,
        // иначе метка задваивается с разными значениями
        let text = text.replacingOccurrences(
            of: #"\s*\(к \d{1,2}:\d{2}\)"#, with: "",
            options: .regularExpression)

        // Линия 1: пред-детект — модель не дёргаем, батарею бережём
        if let reason = preDetectReason(text, codec: codec) {
            return .text(reason: reason, needsCard: true)
        }

        let started = DispatchTime.now()
        var first: Encoded
        switch await encodePass(text, codec: codec, matcher: matcher) {
        case .failure(let outcome):
            return outcome
        case .success(let encoded):
            first = encoded
        }

        // Гейт отрицаний (п.3): проверяется РЕНДЕР ПРИЁМНИКА (машинная
        // развёртка кодов). Провал → до двух перегенераций пивота с
        // усиленной инструкцией; не сошлось — TEXT: телеграмма честнее
        // инверсии смысла.
        var negationTries = 0
        while let negReason = negationGateReason(
                source: text, rendered: codec.render(first.units)),
              negationTries < 2 {
            negationTries += 1
            DictationDebugLog.stage("гейт отрицаний: перегенерация "
                                    + "\(negationTries) (\(negReason))")
            guard case .success(let redo) = await encodePass(
                    text, codec: codec, matcher: matcher,
                    extraRule: negationHint) else { break }
            first = redo
        }
        if let negReason = negationGateReason(
                source: text, rendered: codec.render(first.units)) {
            // Сегментное спасение (долг 5, решение владельца 05.08):
            // в текст уходит только провалившее предложение, не всё
            if let mixed = mixedRescue(source: text, encoded: first,
                                       codec: codec,
                                       pauseSegments: pauseSegments) {
                DictationDebugLog.stage("гейт отрицаний: смешанный режим")
                return finish(mixed, source: text)
            }
            DictationDebugLog.stage("гейт отрицаний: TEXT")
            return .text(reason: negReason, needsCard: true)
        }

        // Гейт сущностей (СРОЧНО 31.07, случай «сын»): каждое
        // существительное/имя пивота обязано прослеживаться до входа.
        // Появилась несводимая сущность → до 2 перегенераций с
        // усиленной инструкцией → всё ещё есть → сообщение ТЕКСТОМ.
        var entityTries = 0
        while let entReason = entityGateReason(source: text,
                                               pivot: first.pivot,
                                               codec: codec),
              entityTries < 2 {
            entityTries += 1
            DictationDebugLog.stage("гейт сущностей: перегенерация "
                                    + "\(entityTries) (\(entReason))")
            guard case .success(let redo) = await encodePass(
                    text, codec: codec, matcher: matcher,
                    extraRule: entityHint) else { break }
            first = redo
        }
        if let entReason = entityGateReason(source: text,
                                            pivot: first.pivot,
                                            codec: codec) {
            if let mixed = mixedRescue(source: text, encoded: first,
                                       codec: codec,
                                       pauseSegments: pauseSegments) {
                DictationDebugLog.stage("гейт сущностей: смешанный режим")
                return finish(mixed, source: text)
            }
            DictationDebugLog.stage("гейт сущностей: TEXT")
            return .text(reason: entReason, needsCard: true)
        }

        // Смысловая петля: Кая сравнивает исходник и развёрнутый
        // результат, переписывает по-русски (идиомы, латиница, потерянные
        // факты) → переписанное снова через конвейер. Один круг.
        guard needsMeaningLoop(source: text, encoded: first),
              let rewritten = await rewriteForMeaning(source: text,
                                                      rendered: first.rendered),
              !rewritten.isEmpty, rewritten != first.rendered,
              case .success(var second) = await encodePass(rewritten,
                                                           codec: codec,
                                                           matcher: matcher)
        else {
            return finish(first, source: text)
        }
        // Гейт чисел ОБЯЗАТЕЛЕН относительно исходной диктовки:
        // числа обязаны пережить и переписывание, и повторный проход
        // (времена нормализуются: 7:30 ↔ 730)
        guard lostNumbers(source: text, pivot: second.pivot).isEmpty
        else {
            return finish(first, source: text)
        }
        // Отрицания обязаны пережить и петлю: провал — откат на first,
        // у которого гейт отрицаний уже пройден
        guard negationGateReason(source: text,
                                 rendered: codec.render(second.units)) == nil
        else {
            return finish(first, source: text)
        }
        // Сущности обязаны пережить и петлю (СРОЧНО 31.07): переписанный
        // текст Софи мог привнести новое — сверка строго с ИСХОДНОЙ
        // диктовкой; провал — откат на first, у которого гейт пройден
        guard entityGateReason(source: text, pivot: second.pivot,
                               codec: codec) == nil
        else {
            return finish(first, source: text)
        }
        DictationDebugLog.stage("петля: переписано и пересчитано")
        second.loopRewritten = rewritten
        // В поле — финал петли: читабельный русский от Каи (машинная
        // развёртка кодов у словаря беднее — ru:None коды дают латиницу).
        // В эфир при этом уходят коды пересчёта: смысл тот же, гейт чисел
        // это гарантирует.
        second.rendered = rewritten
        second.pivotMillis = Double(DispatchTime.now().uptimeNanoseconds
                                    - started.uptimeNanoseconds) / 1e6
        return finish(second, source: text)
    }

    // MARK: Гейт отрицаний (п.3 пост-фермы, приоритет безопасности)

    /// Отрицания входа: («не X» → стем действия X), маркерные («нет»,
    /// «никогда», «нельзя», «отбой/отмена») → пустой стем.
    static func sourceNegations(_ text: String) -> [(marker: String,
                                                     action: String)] {
        let tokens = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        var out: [(String, String)] = []
        for (index, t) in tokens.enumerated() {
            if t == "не", index + 1 < tokens.count {
                let action = tokens[index + 1]
                if action.count >= 2, action != "не" {
                    out.append(("не", negStem(action)))
                }
            } else if ["нет", "никогда", "нельзя"].contains(t) {
                out.append((t, ""))
            } else if t.hasPrefix("отбо") || t.hasPrefix("отмен") {
                out.append(("отмена", ""))
            }
        }
        return out
    }

    /// Стем отрицаемого действия: срез приставки + первые 3 буквы.
    static func negStem(_ w: String) -> String {
        var w = w
        for p in ["по", "под", "при", "за", "вы", "пере", "до", "на",
                  "об", "с", "у"] where w.hasPrefix(p) && w.count - p.count >= 2 {
            w = String(w.dropFirst(p.count))
            break
        }
        return String(w.prefix(3))
    }

    /// Потерянное отрицание не теряет факт — ИНВЕРТИРУЕТ его. Рендер
    /// приёмника обязан содержать И отрицание, И отрицаемое действие.
    /// nil — отрицания целы (или их не было).
    static func negationGateReason(source: String,
                                   rendered: String) -> String? {
        let negations = sourceNegations(source)
        guard !negations.isEmpty else { return nil }
        let renderTokens = rendered.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        let negMarkers: Set<String> = ["не", "нет", "никогда", "нельзя",
                                       "отмена", "отменяется", "not", "no",
                                       "never", "don't", "cancel"]
        let hasMarker = renderTokens.contains { negMarkers.contains($0) }
        // отрицание «при действии»: за маркером в пределах 2 токенов —
        // содержательное слово (супплетивные пары «бери↔брать»,
        // «пошёл↔пойти» стемом не ловятся; голый маркер — ловится)
        var negatedActionExists = false
        for (index, token) in renderTokens.enumerated()
        where negMarkers.contains(token) && token != "нет" {
            for j in (index + 1)...(index + 2) where j < renderTokens.count {
                if renderTokens[j].count >= 3,
                   !negMarkers.contains(renderTokens[j]) {
                    negatedActionExists = true
                }
            }
        }
        for (marker, action) in negations {
            if marker == "отмена" {
                // отмена — собственный маркер, «не» её не заменяет
                guard renderTokens.contains(where: {
                    $0.hasPrefix("отмен") || $0 == "cancel"
                        || $0 == "cancelled" || $0.hasPrefix("отбо")
                }) else { return "гейт отрицаний: потеряна отмена" }
                continue
            }
            guard hasMarker else {
                return "гейт отрицаний: отрицание пропало из рендера"
            }
            if !action.isEmpty {
                let stemFound = renderTokens.contains { token in
                    negStem(token).hasPrefix(String(action.prefix(2)))
                        || token.hasPrefix(action)
                }
                if !stemFound && !negatedActionExists {
                    return "гейт отрицаний: пропало отрицаемое "
                         + "действие «\(action)…»"
                }
            }
        }
        return nil
    }

    /// Подсказка модели при перегенерации после провала гейта отрицаний.
    // MARK: Гейт выдуманных сущностей (СРОЧНЫЙ бриф 31.07)

    /// Служебные en-слова, которые пивот порождает законно без прямого
    /// ru-прообраза (грамматика, связки, местоимения, время/место-дейксис).
    /// Сущности сюда не входят.
    static let pivotFunctionWords: Set<String> = [
        "a", "an", "the", "i", "you", "we", "they", "he", "she", "it",
        "me", "us", "them", "my", "your", "our", "his", "her", "their",
        "this", "that", "these", "those", "there", "here",
        "is", "are", "am", "was", "were", "be", "been", "being",
        "do", "does", "did", "not", "no", "yes", "and", "or", "but",
        "if", "so", "to", "of", "in", "on", "at", "by", "for", "with",
        "from", "as", "than", "then", "now", "soon", "very", "too",
        "will", "would", "can", "could", "should", "must", "may",
        "have", "has", "had", "get", "got", "go", "going", "come",
        "please", "ok", "okay", "about", "up", "down", "out", "back",
        "all", "everything", "something", "nothing", "one", "some",
        "more", "only", "just", "still", "already", "again",
    ]

    /// Сокращения → полные формы (очередь владельца 06.08, промер NUS:
    /// because ×26 ← cos/cuz, tomorrow ×17 ← tmr/tml, people ×11 ←
    /// ppl). ТОЛЬКО трассировка гейта — словарь кодека не трогается.
    /// Зеркало python — entity_gate.EN_ABBREV.
    static let enAbbrev: [String: [String]] = [
        "cos": ["because"], "cuz": ["because"], "coz": ["because"],
        "bcos": ["because"], "bcoz": ["because"],
        "tmr": ["tomorrow"], "tml": ["tomorrow"], "tmrw": ["tomorrow"],
        "ppl": ["people"], "pple": ["people"],
        "u": ["you"], "ur": ["your"], "pls": ["please"], "plz": ["please"],
        "msg": ["message"], "msgs": ["messages"],
        "min": ["minute"], "mins": ["minutes"],
        "mon": ["monday"], "tue": ["tuesday"], "wed": ["wednesday"],
        "thu": ["thursday"], "fri": ["friday"], "sat": ["saturday"],
        "sun": ["sunday"],
        "wat": ["what"], "wen": ["when"], "den": ["then"],
        "dun": ["dont"], "dunno": ["dont", "know"], "knw": ["know"],
        "nt": ["not"], "abt": ["about"], "thx": ["thanks"],
        "ty": ["thanks"], "gd": ["good"], "nite": ["night"],
        "oredi": ["already"], "alr": ["already"], "shld": ["should"],
        "cld": ["could"], "wld": ["would"], "hv": ["have"], "gt": ["got"],
        "aft": ["after"], "b4": ["before"], "l8r": ["later"],
        "sch": ["school"], "ya": ["yes", "yep"], "yah": ["yes", "yep"],
        "yeah": ["yep"], "frnd": ["friend"], "frnds": ["friends", "friend"],
    ]

    /// Транслитерация ru-слова в латиницу — для трассировки NAME: и
    /// внесловарных слов пивота до входа. Простая таблица, без ГОСТа:
    /// нужен префикс-матч, не каноничность.
    static func translit(_ word: String) -> String {
        let map: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e",
            "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k",
            "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
            "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
            "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "",
            "э": "e", "ю": "yu", "я": "ya",
        ]
        return word.lowercased().reduce(into: "") {
            $0 += map[$1] ?? String($1)
        }
    }

    /// Сущности пивота, НЕ прослеживаемые до входа. Принцип числового
    /// гейта: модель не может добавить то, чего не было. Трассировка:
    ///  - словарное en-слово → ru-колонка записи; хоть один ru-стем (≥4)
    ///    содержится в каком-нибудь слове входа → просле́жено;
    ///  - NAME:x и внесловарные слова ≥5 букв → транслит-префикс к
    ///    словам входа;
    ///  - служебные слова, числа и короткие слова не гейтятся.
    static func untracedEntities(source: String, pivot: String,
                                 codec: RMCodec) -> [String] {
        let sourceWords = source.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        // Английская трассировка (очередь владельца 06.08): апострофы
        // (don't → dont; сплит рвал на don+t), склейки соседних слов
        // (may be → maybe), развёрнутые сокращения (tmr → tomorrow) —
        // добавляются к словам источника ТОЛЬКО для трассировки,
        // словарь кодека не трогается. Зеркало python — entity_gate.
        var traceWords = sourceWords
        for chunk in source.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        where chunk.contains("'") {
            let joined = chunk.filter { $0.isLetter }
            if !joined.isEmpty { traceWords.append(String(joined)) }
        }
        for i in sourceWords.indices.dropLast() {
            traceWords.append(sourceWords[i] + sourceWords[i + 1])
        }
        for w in sourceWords { traceWords += Self.enAbbrev[w] ?? [] }
        let sourceTranslit = traceWords.map { translit($0) }
        let sourceExact = Set(sourceWords.map {
            $0.replacingOccurrences(of: "ё", with: "е")
        })

        func tracedByStem(_ ruText: String) -> Bool {
            for ruWord in ruText.lowercased()
                .split(whereSeparator: { !$0.isLetter }) {
                if ruWord.count < 4 {
                    // Лечение 05.08 (live_corpus §5): у коротких ru-слов
                    // («как», «где», «раз») стема ≥4 нет — сверка ЦЕЛЫМ
                    // словом, е/ё нормализованы; подстрока не считается
                    // («карта» не лицензирует «как»). До лечения класс
                    // давал 631 ложный флаг из 3 629, переворачивая 70
                    // сообщений из 1 698 целиком.
                    if sourceExact.contains(String(ruWord)
                        .replacingOccurrences(of: "ё", with: "е")) {
                        return true
                    }
                    continue
                }
                let stem = String(ruWord.prefix(max(4, ruWord.count - 2)))
                if sourceWords.contains(where: { $0.contains(stem) }) {
                    return true
                }
            }
            return false
        }
        func tracedByTranslit(_ latin: String) -> Bool {
            let needle = String(latin.lowercased().prefix(4))
            guard needle.count >= 3 else { return true }   // короткое не гейтим
            if sourceTranslit.contains(where: { $0.hasPrefix(needle) }) {
                return true
            }
            // Словоформы (06.08): пивот-слово начинается со слова
            // источника, удлинение ≤3 (say→says, ask→asked); немая e
            // роняется (come→coming). Короткие служебные (≤3: the,
            // are) не лицензируют — класс «the ↛ theory» (замок).
            let word = latin.lowercased()
            for t in sourceTranslit {
                guard t.count >= 3,
                      !(t.count <= 3 && pivotFunctionWords.contains(t))
                else { continue }
                var stems = [t]
                if t.hasSuffix("e") && t.count >= 4 {
                    stems.append(String(t.dropLast()))
                }
                if stems.contains(where: {
                    word.hasPrefix($0) && word.count - $0.count <= 3 }) {
                    return true
                }
            }
            return false
        }

        // Лицензированные слова (п.1 брифа 31.07, класс (б)): если
        // ru-колонка записи словаря сводится к входу, ВСЕ слова её
        // en-фразы законны — «послезавтра» лицензирует day/after/tomorrow.
        // Защиту от (а) это не ослабляет: «сын» лицензируется только
        // записью, чей ru есть во входе.
        var licensed = Set<String>()
        for entry in codec.entries.values {
            guard let ru = entry.ru, entry.en.contains(" "),
                  tracedByStem(ru) else { continue }
            for w in entry.en.lowercased()
                .split(whereSeparator: { !$0.isLetter }) {
                licensed.insert(String(w))
            }
        }

        // Гейтим СУЩЕСТВИТЕЛЬНЫЕ и имена (бриф 31.07). POS-теггера нет —
        // эвристика по ru-колонке словаря: глаголы (-ть/-чь/-ти), наречия
        // (-о/-но) и прилагательные (-ый/-ий/-ой/-ая/-ее/-ен) не гейтим:
        // законная переводная синонимия («задержусь» → late/«поздно»).
        // Часть существительных на -о (окно) проскочит мимо гейта —
        // осознанный размен: лучше недогейтить, чем заворачивать честные.
        func ruLooksLikeNoun(_ ru: String) -> Bool {
            guard let firstWord = ru.lowercased()
                .split(whereSeparator: { !$0.isLetter }).first else {
                return false
            }
            let w = String(firstWord)
            for suffix in ["ть", "ться", "чь", "ти", "о", "но", "ый", "ий",
                           "ой", "ая", "яя", "ое", "ее", "ен"]
            where w.hasSuffix(suffix) { return false }
            return true
        }
        // Словарная запись: точная форма, затем единственное число
        // (liters → liter, waves → wave)
        func dictRu(_ word: String) -> String?? {
            if let code = codec.byEn[word] { return codec.entries[code]?.ru }
            if word.hasSuffix("es"), let code = codec.byEn[String(word.dropLast(2))] {
                return codec.entries[code]?.ru
            }
            if word.hasSuffix("s"), let code = codec.byEn[String(word.dropLast())] {
                return codec.entries[code]?.ru
            }
            return nil
        }

        var bad: [String] = []
        for raw in pivot.split(separator: " ") {
            let token = String(raw)
            if let name = token.split(separator: ":").last,
               token.lowercased().hasPrefix("name:") {
                if !tracedByTranslit(String(name)) { bad.append(token) }
                continue
            }
            let word = token.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;()\""))
            guard word.count >= 3, word.allSatisfy({ $0.isLetter }),
                  !pivotFunctionWords.contains(word),
                  !licensed.contains(word) else { continue }
            if let entry = dictRu(word) {
                // словарное слово: гейтим только существительные,
                // трассируем через ru-колонку
                if let ru = entry, ruLooksLikeNoun(ru), !tracedByStem(ru),
                   !tracedByTranslit(word) {
                    bad.append(word)
                }
                continue
            }
            // вне словаря: слово обязано сводиться транслитом (правило 9:
            // незнакомое идёт литералом NAME:). Порог 3, не 5: голое
            // «son» без NAME: обязано ловиться так же, как NAME:Son
            if word.count >= 3, !tracedByTranslit(word) {
                bad.append(word)
            }
        }
        return bad
    }

    /// nil — сущности чистые; иначе причина для перегенерации/TEXT.
    static func entityGateReason(source: String, pivot: String,
                                 codec: RMCodec) -> String? {
        let bad = untracedEntities(source: source, pivot: pivot, codec: codec)
        return bad.isEmpty ? nil
            : "гейт сущностей: пивот добавил «\(bad.joined(separator: ", "))»"
    }

    static let entityHint = "CRITICAL: you added things that are NOT in the "
        + "source. Translate ONLY what is said. Never add people, objects "
        + "or facts. Unknown words go as NAME:transliteration literally.\n"

    static let negationHint = "CRITICAL: the source contains a negation. "
        + "Translate EVERY negation explicitly: «не X» -> «not X», "
        + "keep the negated verb. Never drop or invert a negation.\n"

    /// Финальный гейт: применяется к тому, что ЛЯЖЕТ В ПОЛЕ (финал петли
    /// или откат к первому проходу). Салат до человека не доезжает.
    // MARK: Сегментное спасение (долг 5, этап 2; решение владельца 05.08)

    /// Локализация провала гейта: сообщение делится на предложения,
    /// каждая пара (предложение исходника ↔ группа юнитов) гейтится
    /// ОТДЕЛЬНО; провалившие уходят вербатим-оригиналом в esc_literal,
    /// здоровые — кодами. Провод не меняется: esc_literal — штатный юнит.
    ///
    /// Дисциплина, чтобы локализация НЕ ослабила гейт:
    ///  1) гейты бегут на каждом предложении по отдельности — выдумка в
    ///     одном не размывается здоровыми соседями (агрегат по сообщению
    ///     уже однажды прятал локальную выдумку — непреложное №9);
    ///  2) выравнивание строго позиционное и строго 1:1 — числа
    ///     предложений источника и групп юнитов не совпали → nil,
    ///     сообщение уходит текстом целиком, как раньше (безопасная
    ///     деградация, никаких догадок);
    ///  3) после сборки оба гейта прогоняются ещё раз ПО ЦЕЛОМУ —
    ///     собранный результат обязан проходить их без скидок.
    static func mixedRescue(source: String, encoded: Encoded,
                            codec: RMCodec,
                            pauseSegments: [String] = []) -> Encoded? {
        var srcSents = splitSentences(source)
        // Диктовка без пунктуации не делится точками (замер 05.08:
        // 17/17 кандидатов отбиты «одним предложением») — тогда
        // сегментатор источника — паузы STT: вклады чанков склейки,
        // человек сам разделил речь молчанием (решение владельца 05.08).
        if srcSents.count < 2, pauseSegments.count >= 2 {
            srcSents = pauseSegments
        }
        guard srcSents.count >= 2 else { return nil }   // спасать нечего
        let groups = splitUnitGroups(encoded.units, codec: codec)
        guard groups.count == srcSents.count else { return nil }

        let sentEnd = codec.byEn["sent_end"].map { RMCodec.Unit.code($0) }
        var mixedUnits: [RMCodec.Unit] = []
        var rescued = 0
        for (sent, group) in zip(srcSents, groups) {
            let renderedPart = codec.render(group)
            let negFail = negationGateReason(source: sent,
                                             rendered: renderedPart) != nil
            // сущности проверяются ПО ЮНИТАМ группы (entityGateReason
            // ожидает en-пивот, которого у группы нет): существительное
            // из ru-колонки словарного кода обязано прослеживаться до
            // своего предложения источника — та же эвристика, что в
            // глобальном гейте
            let entFail = groupHasUntracedNoun(group, source: sent,
                                               codec: codec)
            // пороговый гейт тоже пер-предложение: салат в одном
            // предложении не должен размываться средним по сообщению;
            // рендер — языка получателя (бриф 06.08)
            let latinSent = dominantIsLatin(sent)
            let finFail = finalGateReason(
                rendered: latinSent ? codec.render(group, lang: "en")
                                    : renderedPart,
                units: group, latinInput: latinSent) != nil
            if negFail || entFail || finFail {
                mixedUnits.append(.lit(sent))
                if let sentEnd { mixedUnits.append(sentEnd) }
                rescued += 1
            } else {
                mixedUnits.append(contentsOf: group)
            }
        }
        guard rescued > 0, rescued < srcSents.count else { return nil }

        // пункт 3: собранное обязано проходить гейты по целому
        let renderedAll = codec.render(mixedUnits)
        guard negationGateReason(source: source, rendered: renderedAll) == nil,
              !groupHasUntracedNoun(mixedUnits, source: source, codec: codec),
              let blob = try? codec.encode(mixedUnits) else { return nil }

        var mixed = encoded
        return Encoded(pivotRaw: mixed.pivotRaw, pivot: mixed.pivot,
                       units: mixedUnits, blob: blob,
                       rendered: renderedAll,
                       chunkCount: mixed.chunkCount,
                       pivotMillis: mixed.pivotMillis,
                       loopRewritten: mixed.loopRewritten)
    }

    /// Несводимое существительное в словарных кодах группы: ru-колонка
    /// кода — существительное (та же POS-эвристика, что в
    /// untracedEntities: глаголы/наречия/прилагательные по суффиксам не
    /// гейтятся) и её стем не находится в предложении-источнике.
    /// Литералы и имена пропускаются: литерал — сам источник.
    static func groupHasUntracedNoun(_ units: [RMCodec.Unit],
                                     source: String,
                                     codec: RMCodec) -> Bool {
        let sourceWords = source.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        func traced(_ ru: String) -> Bool {
            for w in ru.lowercased()
                .split(whereSeparator: { !$0.isLetter }) where w.count >= 3 {
                let stem = String(w.prefix(max(3, w.count - 2)))
                if sourceWords.contains(where: { $0.contains(stem) }) {
                    return true
                }
            }
            return false
        }
        for unit in units {
            guard case .code(let c) = unit,
                  let ru = codec.entries[c]?.ru?.lowercased(),
                  ru.count >= 3 else { continue }
            let verbAdvAdj = ["ть", "чь", "ти", "о", "но", "ый", "ий",
                              "ой", "ая", "ее", "ен"]
                .contains(where: ru.hasSuffix)
            if verbAdvAdj { continue }
            if !traced(ru) { return true }
        }
        return false
    }

    /// Предложения источника: по .?!… и переводам строк. Диктовка без
    /// пунктуации даёт одно предложение — спасение не применяется.
    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ".?!…\n".contains(ch) {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        // Хвост без единой буквы — не предложение (#768 живого корпуса:
        // «)» после «?» становился «предложением», спасение отдавало
        // его вербатимом, а вопрос терялся). Приклеиваем к предыдущему.
        var merged: [String] = []
        for s in out {
            if s.rangeOfCharacter(from: .letters) == nil,
               !merged.isEmpty {
                merged[merged.count - 1] += s
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    /// Группы юнитов по границам предложений (sent_end/question/exclaim).
    /// Код границы остаётся В СВОЕЙ группе (хвостом).
    static func splitUnitGroups(_ units: [RMCodec.Unit],
                                codec: RMCodec) -> [[RMCodec.Unit]] {
        let boundaries = Set(["sent_end", "sent_question", "sent_exclaim"]
            .compactMap { codec.byEn[$0] })
        var groups: [[RMCodec.Unit]] = []
        var cur: [RMCodec.Unit] = []
        for u in units {
            cur.append(u)
            if case .code(let c) = u, boundaries.contains(c) {
                groups.append(cur)
                cur = []
            }
        }
        if !cur.isEmpty { groups.append(cur) }
        return groups
    }

    // internal, не private — тест-замок гейта размера зовёт напрямую
    /// ЗАМОК round-trip (полевой блокер 11.08,
    /// docs/reports/semantic_roundtrip_gate.md): НИКОГДА не отправлять
    /// сообщение, чей декод у получателя ≠ вводу. Частные гейты ловят
    /// классы искажений; этот держит инвариант целиком: реконструкция —
    /// РОВНО приёмной функцией (TextCodec.decompress, путь
    /// DeliveryManager), сравнение с вводом дословное, без нормализаций.
    /// Разошлось — сообщение уходит буквальным текстом.
    static func roundTripGateReason(source: String,
                                    blob: [UInt8]) -> String? {
        guard let rm = RMCodec.shared else { return "словарь недоступен" }
        guard let decoded = try? TextCodec.decompress(
                rm.wireBlob(blob), codec: Envelope.codecSemantic) else {
            return "декод блоба не прошёл"
        }
        guard decoded == source else {
            return "декод получателя расходится с введённым — текстом"
        }
        return nil
    }

    static func finish(_ encoded: Encoded,
                       source: String) -> Outcome {
        // Замок round-trip — ПЕРВЫМ: инвариант важнее всех эвристик
        if let reason = roundTripGateReason(source: source,
                                            blob: encoded.blob) {
            DictationDebugLog.stage("замок round-trip: TEXT (\(reason))")
            return .text(reason: reason, needsCard: true)
        }
        // Финальный гейт меряет рендер ЯЗЫКА ПОЛУЧАТЕЛЯ (бриф 06.08):
        // латинский вход — en-рендер, иначе прежний (ru)
        let latinInput = dominantIsLatin(source)
        let gateRendered = latinInput
            ? (RMCodec.shared?.render(encoded.units, lang: "en")
               ?? encoded.rendered)
            : encoded.rendered
        if let reason = finalGateReason(rendered: gateRendered,
                                        units: encoded.units,
                                        latinInput: latinInput) {
            DictationDebugLog.stage("финальный гейт: TEXT (\(reason))")
            return .text(reason: reason, needsCard: true)
        }
        // 3в (29.07): гейт выбирает МЕНЬШЕЕ — семантический блоб больше
        // сжатого текста → честно шлём текст. С 05.08 сравнение — с тем
        // текстом, который РЕАЛЬНО уйдёт при отказе (исходник, лучший из
        // store/zlib), а не с zlib рендера (аудит гейта размера, кейс
        // #5361: блоб 42 Б проходил против рендера, проигрывая
        // исходнику 38 Б).
        if let codec = RMCodec.shared,
           codec.wireBlob(encoded.blob).count
               >= TextCodec.best(source).data.count {
            DictationDebugLog.stage("гейт размера: текст короче")
            return .text(reason: "текст короче семантики", needsCard: false)
        }
        // Красная сессия 05.08, п.2: двусторонняя проверка — гейты выше
        // ловят ДОБАВЛЕННОЕ (пивот→вход), этот ловит ПОТЕРЯННОЕ
        // (вход→юниты). Прецеденты замера: «уважаемая лошадь» → «Милая»
        // (#5), вопрос целиком испарился (#768). Потеря части сообщения
        // хуже отказа сжимать — текстом (решение владельца 05.08).
        if let codec = RMCodec.shared,
           let missing = missingNounGateReason(source: source,
                                               units: encoded.units,
                                               rendered: encoded.rendered,
                                               codec: codec) {
            DictationDebugLog.stage("гейт пропажи: TEXT (\(missing))")
            return .text(reason: missing, needsCard: true)
        }
        // Красная сессия 05.08, п.3: числа РЕНДЕРА не гейтились —
        // «бедная» → «Бедный 1» (#633): цифра из ниоткуда доставлялась.
        // Гейт чисел выше смотрит только числа источника в пивоте.
        if let fabricated = fabricatedNumberReason(source: source,
                                                   rendered: encoded.rendered) {
            DictationDebugLog.stage("гейт чисел рендера: TEXT (\(fabricated))")
            return .text(reason: fabricated, needsCard: true)
        }
        DictationDebugLog.stage("кодирование готово (\(encoded.blob.count) Б)")
        return .semantic(encoded)
    }

    /// Служебные слова источника, которые перефраз законно теряет.
    private static let ruDroppable: Set<String> = [
        "если", "когда", "тогда", "здесь", "чтобы", "потому", "поэтому",
        "просто", "очень", "только", "ещё", "еще", "уже", "вообще",
        "конечно", "наверное", "может", "можно", "нужно", "надо",
        "есть", "нет", "этот", "эта", "это", "этом", "этим", "того",
        "тому", "всем", "всех", "чего", "кого", "какая", "какой",
        "которые", "который", "некоторые", "привет", "пожалуйста",
        "здравствуйте", "спасибо", "тебя", "тебе", "меня", "мной",
        "нему", "свои", "своими", "свой", "своя", "пока", "итак",
        "сейчас", "теперь", "разве", "вроде", "сами", "вашей", "ваша",
        "нельзя", "давайте", "буду", "будет", "будем", "могу", "хочу",
    ]

    /// Хвосты глаголов/прилагательных/наречий: их перефраз меняет
    /// свободно, гейт пропажи смотрит только существительные (та же
    /// эвристика, что в сегментном спасении). Прошедшее время («-ла»,
    /// «-ли») — из замера 05.08: «поняла», «успела» флагались зря.
    private static let ruNonNounSuffixes = [
        "ть", "чь", "ти", "но", "ый", "ий", "ой", "ая", "яя", "ое",
        "ее", "ен", "ут", "ют", "ат", "ят", "ит", "ет", "ешь", "ишь",
        "те", "сь", "ся", "ла", "ло", "ли", "ые", "ие", "ду", "гу",
    ]

    /// Английские междометия и безапострофные формы (бриф 06.08 п.4):
    /// NUS-замер флаговал их «потерянными словами» — перефраз их
    /// законно теряет. Ряды ha/he/hm/ho ловятся по составу букв
    /// (hahaha, hmmm любой длины). Зеркало python — rescue_measure.
    private static let enDroppable: Set<String> = [
        "haha", "hehe", "hiya", "heya", "alright", "okay", "okie",
        "yeah", "yep", "yeps", "oops", "ohhh", "haiz", "sian", "walao",
        "aiyo", "aiya", "wahh", "huhu", "erm", "ermm", "hmm", "lolx",
        "lolz", "dont", "cant", "wont", "didnt", "doesnt", "isnt",
        "wasnt", "arent", "havent", "hasnt", "gonna", "wanna", "gotta",
        "kinda", "sorta", "thats", "whats", "youre", "theyre", "weve",
        "youve", "goodnight", "gudnite", "nite",
    ]

    static func enDroppableWord(_ w: String) -> Bool {
        if enDroppable.contains(w) { return true }
        let letters = Set(w)
        guard letters.count <= 2 else { return false }
        return [Set("ha"), Set("he"), Set("hm"), Set("ho")]
            .contains { letters.isSubset(of: $0) }
    }

    /// Существительное источника, не прослеживаемое в юниты, — потеря.
    /// Трассировка: рендер + литералы + ПОЛНЫЕ ru-колонки и en-слова
    /// кодовых юнитов (рендер показывает только первый ru-вариант, а
    /// перефраз живёт в синонимах статьи) + транслит для латиницы
    /// («убуде» ↔ ubud). Пороги и списки — из замера на 398 смысловых
    /// исходах живого корпуса (rescue_farm / live_corpus 05.08).
    static func missingNounGateReason(source: String,
                                      units: [RMCodec.Unit],
                                      rendered: String,
                                      codec: RMCodec) -> String? {
        var parts: [String] = [rendered.lowercased()]
        for unit in units {
            switch unit {
            case .lit(let s): parts.append(s.lowercased())
            case .name(let n): parts.append(n.lowercased())
            case .code(let c):
                if let e = codec.entries[c] {
                    if let ru = e.ru { parts.append(ru.lowercased()) }
                    parts.append(e.en.lowercased())
                }
            case .num(let n): parts.append(String(n))
            default: break
            }
        }
        let hay = parts.joined(separator: " ")
            .replacingOccurrences(of: "ё", with: "е")
        for raw in source.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted) {
            let w = raw.replacingOccurrences(of: "ё", with: "е")
            guard w.count >= 4, !ruDroppable.contains(w),
                  !enDroppableWord(w),
                  !ruNonNounSuffixes.contains(where: { w.hasSuffix($0) })
            else { continue }
            if hay.contains(String(w.prefix(4))) { continue }
            let t = translit(w)
            if t.count >= 4, hay.contains(String(t.prefix(4))) { continue }
            return "потеряно слово «\(raw)»"
        }
        return nil
    }

    /// Словесные числительные: рендер законно даёт цифру («два» → 2).
    private static let ruNumberWords: [String: String] = [
        "ноль": "0", "один": "1", "одна": "1", "одну": "1", "два": "2",
        "две": "2", "три": "3", "четыре": "4", "пять": "5", "шесть": "6",
        "семь": "7", "восемь": "8", "девять": "9", "десять": "10",
    ]

    /// Цифры в рендере, которых нет в источнике (ни цифрой, ни словом),
    /// — фабрикация: «Бедный 1» из «бедная» (#633 живого корпуса).
    static func fabricatedNumberReason(source: String,
                                       rendered: String) -> String? {
        var allowed = Set(numberTokens(in: source))
        let low = source.lowercased()
        for (word, digit) in ruNumberWords where low.contains(word) {
            allowed.insert(digit)
        }
        for n in numberTokens(in: rendered) where !allowed.contains(n) {
            // нормализация времени: «730» покрывает 7 и 30 и наоборот
            if allowed.contains(where: { $0.contains(n) || n.contains($0) }) {
                continue
            }
            return "число «\(n)» не из источника"
        }
        return nil
    }

    private static func numberTokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
    }

    /// Гейт финального текста. Латиница считается ПО ТОКЕНАМ с
    /// нормализацией (don't — латинский токен); имена (esc_name) не в
    /// счёт. Калибровка по полевому салату 28.07 (сжато 575→119):
    /// пороги из ТЗ >25% латиницы и <60% словарных оставлены грубой
    /// сетью, но замер дал: салат = 13% латиницы / 76% словарных —
    /// под ними проходит; разделяет его число РАЗНЫХ латинских слов
    /// (салат 5: don't/percent/appears/pass/cash; худший эталон 1).
    static func finalGateReason(rendered: String,
                                units: [RMCodec.Unit],
                                latinInput: Bool = false) -> String? {
        var names = Set<String>()
        for unit in units {
            if case .name(let n) = unit { names.insert(n.lowercased()) }
        }
        let tokens = rendered.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
            .filter { $0.count >= 2 && !names.contains($0) }
        guard tokens.count >= 6 else { return nil }

        // «Чужое письмо» в рендере ПОЛУЧАТЕЛЯ (бриф 06.08 п.2):
        // ru-рендер меряется латиницей (как раньше), en-рендер —
        // кириллицей. До починки английский вход мерился ru-рендером
        // и гейт хоронил его всегда (NUS: 336 срабатываний).
        let foreignTokens = tokens.filter { token in
            latinInput
                ? token.contains { ("а"..."я").contains($0) || $0 == "ё" }
                : token.contains { $0.isASCII && $0.isLetter }
        }
        if Double(foreignTokens.count) / Double(tokens.count) > 0.25 {
            return "в тексте слишком много непереведённых слов"
        }
        let distinctForeign = Set(foreignTokens)
        if distinctForeign.count >= 3 {
            return "смысл не сложился: непереведённые слова ("
                 + distinctForeign.sorted().prefix(3).joined(separator: ", ") + "…)"
        }
        // Порог словарности — только для текстов ≥12 токенов: на коротких
        // метрика шумит (падежи петли: «воду/рынке/дам» мимо лексикона —
        // ферма 28.07, corpus03). Совпадение — по 3-буквенному префиксу
        // (ru) / лексикону языка (en).
        guard tokens.count >= 12 else { return nil }
        let dictionary = tokens.filter { word in
            latinInput
                ? lexiconCovers(word, latin: true)
                : ruLexicon.words.contains(word)
                    || (word.count >= 3
                        && ruLexicon.prefixes3.contains(String(word.prefix(3))))
        }
        if Double(dictionary.count) / Double(tokens.count) < 0.6 {
            return "смысл не сложился: слишком мало словарных слов"
        }
        return nil
    }

    /// Один проход конвейера: пивот (чанками) → санитайзер → матчер →
    /// кодек → gate. failure — готовый текстовый Outcome (для первого
    /// прохода); в петле любой failure означает «оставить первый итог».
    private enum PassOutcome {
        case success(Encoded)
        case failure(Outcome)
    }

    private static func encodePass(_ text: String, codec: RMCodec,
                                   matcher: PivotMatcher,
                                   extraRule: String? = nil) async -> PassOutcome {
        let started = DispatchTime.now()
        let pivotRaw: String
        let chunkCount: Int
        switch await pivotFor(text, extraRule: extraRule) {
        case .ok(let raw, let count):
            pivotRaw = raw
            chunkCount = count
        case .modelFailed:
            return .failure(.text(reason: "модель не ответила", needsCard: false))
        case .chunkTooShort(let chunkWords, let pivotWords):
            // контроль чанка: повтор не помог — честно текстом
            return .failure(.text(reason: "пивот слишком короткий "
                                + "(\(pivotWords) слов на \(chunkWords) в чанке)",
                                  needsCard: true))
        }
        let pivotMillis = Double(DispatchTime.now().uptimeNanoseconds
                                 - started.uptimeNanoseconds) / 1e6

        let pivot = sanitize(pivotRaw, codec: codec)
        // П1 слой 3: чат-контекст — protected-диапазон запрещён
        let units = matcher.units(fromPivot: pivot, allowProtected: false)
        guard !pivot.isEmpty, !units.isEmpty else {
            return .failure(.text(reason: "пивот пустой", needsCard: true))
        }
        let blob: [UInt8]
        do {
            blob = try codec.encode(units)
        } catch {
            // Причина обязана быть честной: раньше здесь стояло
            // «пивот пустой» на ЛЮБОЙ отказ кодека, включая слишком
            // длинный литерал (стресс 03.08). Сообщение уходит текстом
            // целиком — потери нет, но человек видит настоящую причину.
            return .failure(.text(
                reason: (error as? LocalizedError)?.errorDescription
                    ?? "кодек отказался: \(error)", needsCard: true))
        }

        // Линия 3: gate качества — числа, полнота, доля literal
        if let reason = gateReason(source: text, pivot: pivot,
                                   units: units, blob: blob) {
            return .failure(.text(reason: reason, needsCard: true))
        }

        return .success(Encoded(pivotRaw: pivotRaw, pivot: pivot,
                                units: units, blob: blob,
                                rendered: codec.render(units),
                                chunkCount: chunkCount,
                                pivotMillis: pivotMillis))
    }

    // MARK: Смысловая петля на отправителе

    /// Нужна ли петля: латиница или literal в результате — всегда
    /// (английское слово доехало как есть); чистый рендер — всё равно
    /// гоняем для исходников длиннее 15 слов: идиомы и молчаливые потери
    /// фактов («старое кафе» пропало) бывают и без латиницы. Коротким
    /// (<15 слов) петля не нужна — там нечему теряться.
    static func needsMeaningLoop(source: String, encoded: Encoded) -> Bool {
        let hasLatin = encoded.rendered.contains { $0.isLetter && $0.isASCII }
        let hasLit = encoded.units.contains {
            if case .lit = $0 { return true } else { return false }
        }
        return hasLatin || hasLit || wordCount(source) > 15
    }

    /// Системный промпт петли (общий со смоуком tools/ — менять синхронно).
    static let meaningLoopSystemPrompt = """
    Ты сравниваешь смысл двух русских текстов и переписываешь второй.
    Перепиши второй текст по-русски так, чтобы он передавал мысль первого: \
    естественные формулировки, идиомы разворачивай по смыслу \
    (ran out = закончилось), английские слова переводи, все числа, места \
    и имена из первого сохрани точно. Ласковые обращения и уменьшительные \
    (солнышко, милая, зайка, братан) сохраняй и переводи узнаваемо — \
    не выбрасывай и не заменяй нейтральными. Не добавляй фактов. Если \
    второй текст потерял важный факт первого — верни его.
    Ответ — только переписанный текст, без пояснений.
    """

    static func meaningLoopUserPrompt(source: String, rendered: String) -> String {
        "Первый текст (исходник):\n" + source
        + "\n\nВторой текст:\n" + rendered
        + "\n\nПереписанный второй текст:"
    }

    /// Один вызов Каи (P1, temp 0): исходник + развёрнутый результат →
    /// естественный русский с возвращёнными фактами. nil — не вышло
    /// (остаёмся с первым итогом).
    private static func rewriteForMeaning(source: String,
                                          rendered: String) async -> String? {
        let request = LLMRequest(
            prompt: meaningLoopUserPrompt(source: source, rendered: rendered),
            systemPrompt: meaningLoopSystemPrompt,
            maxTokens: min(300, wordCount(source) * 4 + 40),
            samplingOverride: .extraction)
        do {
            let response = try await ModelScheduler.shared
                .withProvider(.outgoing) { try await $0.generate(request) }
            return response.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        } catch {
            return nil
        }
    }

    // MARK: Линия 1 — пред-детект (детерминированный, без модели)

    /// Русский лексикон словаря: слова из ru-полей + префиксы (4 буквы)
    /// для грубого снятия окончаний.
    private static let ruLexicon: (words: Set<String>, prefixes: Set<String>,
                                   prefixes3: Set<String>) = {
        var words = Set<String>()
        var prefixes = Set<String>()
        var prefixes3 = Set<String>()
        guard let codec = RMCodec.shared else {
            return (words, prefixes, prefixes3)
        }
        for e in codec.entries.values {
            guard let ru = e.ru else { continue }
            for w in ru.lowercased().split(whereSeparator: { !$0.isLetter }) {
                let word = String(w)
                guard word.count >= 3 else { continue }
                words.insert(word)
                prefixes.insert(String(word.prefix(4)))
                prefixes3.insert(String(word.prefix(3)))
            }
        }
        return (words, prefixes, prefixes3)
    }()

    /// Английский лексикон — та же конструкция из en-колонки словаря
    /// (бриф 06.08: язык входа выбирает колонку; русский фильтр резал
    /// 89% английского — блокер запуска). Служебные — pivotFunctionWords.
    private static let enLexicon: (words: Set<String>, prefixes: Set<String>)
    = {
        var words = Set<String>()
        var prefixes = Set<String>()
        guard let codec = RMCodec.shared else { return (words, prefixes) }
        for e in codec.entries.values {
            for w in e.en.lowercased()
                .split(whereSeparator: { !$0.isLetter }) {
                let word = String(w)
                guard word.count >= 3 else { continue }
                words.insert(word)
                if word.count >= 4 { prefixes.insert(String(word.prefix(4))) }
            }
        }
        return (words, prefixes)
    }()

    private static let enWordsByLength: [Int: [[Character]]] = {
        var out: [Int: [[Character]]] = [:]
        for w in enLexicon.words { out[w.count, default: []].append(Array(w)) }
        return out
    }()

    /// Язык входа по письму: перевес латиницы — en, иначе ru
    /// (смешанное и пустое — ru, прежнее поведение).
    static func dominantIsLatin(_ text: String) -> Bool {
        var cyr = 0, lat = 0
        for ch in text.lowercased() where ch.isLetter {
            if ("а"..."я").contains(ch) || ch == "ё" { cyr += 1 }
            else if ch.isASCII { lat += 1 }
        }
        return lat > cyr
    }

    /// Слово покрыто лексиконом языка: точное совпадение, префикс-4
    /// или служебная форма.
    static func lexiconCovers(_ w: String, latin: Bool = false) -> Bool {
        if latin {
            return enLexicon.words.contains(w)
                || (w.count >= 4
                    && enLexicon.prefixes.contains(String(w.prefix(4))))
                || pivotFunctionWords.contains(w)
        }
        return ruLexicon.words.contains(w)
            || (w.count >= 4 && ruLexicon.prefixes.contains(String(w.prefix(4))))
            || ruFunctionForms.contains(w)
    }

    /// Схлопывание повторов: 3 и более одинаковых буквы подряд → одна
    /// («жжжди» → «жди»). Двойные буквы — законная орфография, не трогаем.
    static func collapseRepeats(_ word: String) -> String {
        word.replacingOccurrences(of: #"(.)\1{2,}"#, with: "$1",
                                  options: .regularExpression)
    }

    /// Слова лексикона по длинам — кандидаты расстояния 1 отличаются
    /// длиной не больше чем на 1.
    private static let ruWordsByLength: [Int: [[Character]]] = {
        var out: [Int: [[Character]]] = [:]
        for w in ruLexicon.words {
            out[w.count, default: []].append(Array(w))
        }
        return out
    }()

    /// Расстояние Дамерау-Левенштейна ≤1: замена, вставка, пропуск
    /// или перестановка соседних букв.
    static func withinDamerauLevenshtein1(_ a: [Character],
                                          _ b: [Character]) -> Bool {
        if a.count == b.count {
            var diff: [Int] = []
            for i in a.indices where a[i] != b[i] {
                diff.append(i)
                if diff.count > 2 { return false }
            }
            if diff.count <= 1 { return true }
            return diff[1] == diff[0] + 1
                && a[diff[0]] == b[diff[1]] && a[diff[1]] == b[diff[0]]
        }
        guard abs(a.count - b.count) == 1 else { return false }
        let (s, l) = a.count < b.count ? (a, b) : (b, a)
        var i = 0                   // l длиннее на 1: одна вставка/пропуск
        while i < s.count && s[i] == l[i] { i += 1 }
        return s[i...] == l[(i + 1)...]
    }

    /// Нормализация токена, не прошедшего лексикон с первого раза
    /// (решение владельца 03.08, docs/reports/pregate_analysis_2026-08-03.md):
    ///   1) схлопнуть повторы букв и попробовать лексикон снова;
    ///   2) расстояние Дамерау-Левенштейна 1 до ПОЛНОГО слова лексикона
    ///      («мсот» → «мост», «вдоа» → «вода»); токены длиной ≤3
    ///      расстоянием НЕ лечатся — ложные срабатывания на предлогах.
    /// Кандидаты расстояния — только полные слова, НЕ префиксное
    /// покрытие вариантов: правка, меняющая префикс-4, «лечит» любое
    /// слово в чужую словарную семью («заголовок» → «заболовок» по
    /// префиксу «забо») и размывает лексический прегейт до пропуска
    /// техтекста (ломался замок screenMessageGoesText).
    /// Зеркало python — normalized_in_lexicon в farm_text.py.
    static func normalizedInLexicon(_ word: String,
                                    latin: Bool = false) -> Bool {
        let collapsed = collapseRepeats(word)
        if collapsed != word && lexiconCovers(collapsed, latin: latin) {
            return true
        }
        let chars = Array(collapsed)
        guard chars.count > 3 else { return false }
        let byLength = latin ? Self.enWordsByLength : Self.ruWordsByLength
        for len in (chars.count - 1)...(chars.count + 1) {
            for cand in byLength[len] ?? []
            where withinDamerauLevenshtein1(chars, cand) {
                return true
            }
        }
        return false
    }

    /// Содержательные слова: буквенные, длиной ≥3.
    static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    /// Служебные русские формы (местоимения, связки, частые формы
    /// глагола «быть»): лексикон строится из ru-строк словаря, где таких
    /// форм нет, но пивот-модель переводит их без потерь — прегейт не
    /// должен считать их «вне словаря смыслов».
    static let ruFunctionForms: Set<String> = [
        "неё", "него", "ней", "нём", "ему", "ей", "ею", "ими", "ним", "ними",
        "нам", "вам", "нами", "вами", "тебе", "тебя", "меня", "мне", "мной",
        "нас", "вас", "его", "её", "их", "сам", "сама", "сами", "самому",
        "самой", "себе", "себя", "будет", "буду", "будем", "будешь",
        "будут", "будете", "был", "была", "были", "было", "есть", "нет",
        "чтобы", "потому", "поэтому", "если", "когда", "тогда", "здесь",
        "там", "тут", "этот", "эта", "это", "эти", "тот", "той", "том",
    ]

    /// Слова с заглавной буквы НЕ в начале предложения — вероятные
    /// имена собственные (в нижнем регистре, для сверки с contentWords).
    static func probableNameWords(_ text: String) -> Set<String> {
        var names = Set<String>()
        var sentenceStart = true
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let first = raw.first(where: { $0.isLetter }) else {
                continue
            }
            let word = raw.lowercased()
                .filter { $0.isLetter }
            if first.isUppercase && !sentenceStart && word.count >= 3 {
                names.insert(word)
            }
            sentenceStart = raw.contains(where: { ".!?".contains($0) })
        }
        return names
    }

    /// Причина сразу уйти текстом, не тратя модель. nil — можно пробовать.
    static func preDetectReason(_ text: String, codec: RMCodec) -> String? {
        // >15% цифр среди букв и цифр — технический текст, не речь
        var digits = 0, letters = 0
        for ch in text {
            if ch.isNumber && ch.isASCII { digits += 1 }
            else if ch.isLetter { letters += 1 }
        }
        if digits + letters > 0,
           Double(digits) / Double(digits + letters) > 0.15 {
            return "в тексте слишком много цифр"
        }

        // Слова вне русского лексикона словаря. Перекалибровка 29.07
        // (Ф1 v1.1: покрытие ru 100%): корпус — 0–36%, «Марина» — 32%,
        // техтекст со скрина — 39%. Маржа сузилась до ~3пп — лексический
        // прегейт при полном словаре исчерпал разделяющую силу; порог
        // 37% — тонкий, но последняя оборона не он: цифровая проверка
        // (>15%) и финальный гейт держат салат независимо.
        // Имена (заглавная не в начале предложения) — вне знаменателя:
        // они законно вне словаря и уйдут esc_name (фикстура 28.07).
        // Нормализация опечаток ДО подсчёта доли (решение владельца
        // 03.08): токен, не прошедший лексикон, лечится схлопыванием
        // повторов и расстоянием 1 — см. normalizedInLexicon.
        let probableNames = probableNameWords(text)
        let words = contentWords(text).filter { !probableNames.contains($0) }
        guard words.count >= 4 else { return nil }   // короткое — пусть пробует
        // Уточнение владельца 06.08: язык НЕ определяется — слово
        // покрыто, если покрыто ХОТЬ ОДНОЙ колонкой словаря (союз).
        // Смешанные («скинь tracking number завтра») проходят
        // естественно. Замер вариантов: союз против алфавита — NUS
        // одинаково (1680/2223), союз добавляет +3,7% мусора жанра
        // форвардов (карма-карточки) на русском корпусе — цена принята,
        // ручной ввод так не выглядит; выбор по цифрам 06.08.
        let covered = words.filter { w in
            lexiconCovers(w, latin: false) || lexiconCovers(w, latin: true)
                || normalizedInLexicon(w, latin: false)
                || normalizedInLexicon(w, latin: true)
        }.count
        if Double(words.count - covered) / Double(words.count) > 0.37 {
            return "больше половины слов вне словаря смыслов"
        }
        return nil
    }

    // MARK: Линия 3 — gate качества после пивота

    static func numbersSet(_ text: String) -> Set<Int> {
        var out = Set<Int>()
        var current = ""
        for ch in text {
            if ch.isNumber && ch.isASCII { current.append(ch) }
            else if !current.isEmpty { out.insert(Int(current) ?? 0); current = "" }
        }
        if !current.isEmpty { out.insert(Int(current) ?? 0) }
        return out
    }

    /// Числа исходника, потерянные пивотом. Времена нормализуются:
    /// составное время в ПИВОТЕ (730, 0730 ← «7:30») покрывает свои
    /// компоненты 7 и 30 — STT пишет «07:30», модель может слить в
    /// «730», это не потеря (полевой тест-1, ферма 28.07). Расширяется
    /// только пивот-множество — требования к исходнику строгие.
    static func lostNumbers(source: String, pivot: String) -> Set<Int> {
        var covered = numbersSet(pivot)
        for n in covered where (100...2359).contains(n) && n % 100 < 60 {
            covered.insert(n / 100)
            covered.insert(n % 100)
        }
        return numbersSet(source).subtracting(covered)
    }

    /// Причина забраковать пивот. nil — пивот годен.
    static func gateReason(source: String, pivot: String,
                           units: [RMCodec.Unit], blob: [UInt8]) -> String? {
        // а) все числа исходника обязаны выжить в пивоте
        // (времена нормализуются: 7:30 ↔ 730)
        let lost = lostNumbers(source: source, pivot: pivot)
        if !lost.isEmpty {
            return "пивот потерял числа: \(lost.sorted().map(String.init).joined(separator: ", "))"
        }
        // б) пивот не короче 30% содержательных слов исходника
        let sourceWords = contentWords(source).count
        let pivotWords = pivot.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        if sourceWords >= 4, Double(pivotWords) < 0.3 * Double(sourceWords) {
            return "пивот слишком короткий (\(pivotWords) слов на \(sourceWords) в исходнике)"
        }
        // в) literal-байты < 50% кодированного
        let litBytes = units.reduce(0) { sum, u in
            if case .lit(let s) = u { return sum + s.utf8.count }
            return sum
        }
        if blob.count > 0, Double(litBytes) / Double(blob.count) >= 0.5 {
            return "больше половины байт — непокрытый текст"
        }
        return nil
    }

    // MARK: Линия 2 — пивот чанками по предложениям

    /// Разбивка на предложения (грубая: .!?… и переводы строк).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "…" || ch == "\n" {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Число слов (по пробелам) — для решений чанкера.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: Словный чанкер — диктовки без пунктуации

    /// Маркеры начала новой мысли в потоке речи: границу режем ПЕРЕД ними.
    static let thoughtMarkers: Set<String> = [
        "и", "а", "но", "вот", "потом", "короче", "ну", "значит",
        "если", "что", "когда", "чтобы", "только", "там", "тут",
    ]

    /// Слово для сравнения с маркером: без регистра и знаков.
    private static func markerForm(_ w: Substring) -> String {
        w.lowercased().filter { $0.isLetter }
    }

    /// Словный чанкер: цель ~15 слов (чанки 10–20). Граница — ближайший
    /// к цели маркер начала мысли в окне ±4 слова (режем перед маркером);
    /// маркера нет — режем ровно по цели. Хвост ≤20 слов — целиком.
    static func wordChunks(_ text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count > 20 else {
            return words.isEmpty ? [] : [words.joined(separator: " ")]
        }
        var out: [String] = []
        var start = 0
        while start < words.count {
            if words.count - start <= 20 {
                out.append(words[start...].joined(separator: " "))
                break
            }
            let target = start + 15
            var cut = target
            for delta in 0...4 {   // ближайший к цели; при равенстве — раньше
                let earlier = target - delta
                let later = target + delta
                if thoughtMarkers.contains(markerForm(words[earlier])) {
                    cut = earlier; break
                }
                if delta > 0, later < words.count,
                   thoughtMarkers.contains(markerForm(words[later])) {
                    cut = later; break
                }
            }
            out.append(words[start..<cut].joined(separator: " "))
            start = cut
        }
        return out
    }

    /// Чанки: предложения группами 1–3 (~250 симв.); предложение длиннее
    /// 25 слов (диктовка без пунктуации — одно «предложение» на всё)
    /// дорезается словным чанкером, его куски обратно не склеиваются.
    static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var length = 0
        func flushGroup() {
            guard !current.isEmpty else { return }
            out.append(current.joined(separator: " "))
            current = []; length = 0
        }
        for s in sentences(text) {
            if wordCount(s) > 25 {
                flushGroup()
                out.append(contentsOf: wordChunks(s))
                continue
            }
            if !current.isEmpty && (length + s.count > 250 || current.count == 3) {
                flushGroup()
            }
            current.append(s)
            length += s.count
        }
        flushGroup()
        return out
    }

    /// Итог пивота: текст + число чанков, или причина отказа.
    enum PivotResult: Sendable {
        case ok(String, chunks: Int)
        case modelFailed
        case chunkTooShort(chunkWords: Int, pivotWords: Int)
    }

    /// Слова пивота (латиница/цифры) — для контроля покрытия чанка.
    private static func pivotWordCount(_ pivot: String) -> Int {
        pivot.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    // MARK: Чат-промпт пивота — БЕЗ protected-кодов (П1, 28.07)
    // sos_*/injury_*/state_*/hazard_* — словарь SOS-вкладки с её
    // промптом и подтверждением человека; из обычного чата protected
    // недостижим тремя слоями: промпт (здесь) → санитайзер → матчер.
    // Правило про обращения (П4) — по умолчанию, не стиль.
    static let chatPromptTemplate = """
    You convert dictated Russian speech (raw speech-to-text: no punctuation, filler words, self-corrections) into ONE line of minimal clean English pivot for a semantic codec.

    HARD RULES:
    1. Output exactly one line, nothing else. No "EN:", no explanations.
    2. Short common English words, all lowercase.
    3. ALL numbers as digits: write 6, not six. Times as digits: "at 6", "at 8 in the evening".
    4. Keep every fact: numbers, times, dates, places, names, quantities, needs. Apply self-corrections ("в пятницу то есть в субботу" -> saturday only). Drop fillers (ну, короче, слушай, эээ, блин) and repeats.
    5. Affectionate address words and diminutives (солнышко, милая, зайка, братан) are FACTS: keep them, translate recognizably (sunshine, honey, bunny, buddy), never drop them.
    6. EVERY name of a person or a place MUST be marked: NAME:Mark, NAME:Boston. Never write a bare name.
    7. Plain words ONLY. Never use snake_case, underscores or special codes of any kind.
    8. PRESERVE the sentence boundaries of the source: end every sentence with . or ? or ! exactly as the source means it.
    9. NEVER add people, objects or facts that are not in the source. An unfamiliar word or a word with no direct English equivalent goes as a literal NAME:transliteration. Synonyms and generalizations are FORBIDDEN: translate the exact word, do not replace it with a broader one.

    Examples:
    RU: ну я это самое буду минут через десять наверное
    EN: be there soon in 10 minutes.
    RU: слушай генератор сломался бензина нет купи литров пять
    EN: the generator is broken no petrol buy 5 liters
    RU: прием прием как слышно это саша
    EN: radio check can you hear me this is NAME:Sasha
    RU: передай марине что андрей уже в ростове
    EN: tell NAME:Marina that NAME:Andrey is already in NAME:Rostov
    RU: солнышко я соскучился очень сильно скучаю по тебе
    EN: sunshine i miss you i miss you so much
    RU: волны сегодня здоровые лодки не пойдут
    EN: waves are big. boats do not go today.
    RU: слушай отбой по рынку встречаемся у моста
    EN: the market is cancelled. meet at the bridge.
    """

    private static func pivotFor(_ text: String,
                                 extraRule: String? = nil) async -> PivotResult {
        // Короткое — одним вызовом; длинное по символам ИЛИ словам — чанками
        let needsChunking = text.count > 250 || wordCount(text) > 25
        let pieces = needsChunking ? chunks(text) : [text]
        let system = chatPromptTemplate

        var pivots: [String] = []
        for (index, piece) in pieces.enumerated() {
            var extra = pieces.count > 1
                ? "Переведи ВСЁ, не объединяй и не сокращай.\n" : ""
            if let extraRule { extra = extraRule + extra }
            guard let first = await pivotForChunk(piece, extra: extra,
                                                  system: system) else {
                return .modelFailed
            }
            DictationDebugLog.stage("пивот-чанк \(index + 1)/\(pieces.count)")
            var chunkPivot = first
            // Контроль чанка: пивот <40% слов чанка → один повтор
            // с усиленной инструкцией → снова мало → всё сообщение в TEXT
            let chunkWords = wordCount(piece)
            if pieces.count > 1,
               Double(pivotWordCount(chunkPivot)) < 0.4 * Double(chunkWords) {
                let stronger = "Переведи КАЖДОЕ слово исходника. НИЧЕГО не "
                             + "пропускай, не объединяй и не сокращай — "
                             + "перевод должен быть такой же длины.\n"
                guard let retried = await pivotForChunk(piece, extra: stronger,
                                                        system: system) else {
                    return .modelFailed
                }
                chunkPivot = retried
                if Double(pivotWordCount(chunkPivot)) < 0.4 * Double(chunkWords) {
                    return .chunkTooShort(chunkWords: chunkWords,
                                          pivotWords: pivotWordCount(chunkPivot))
                }
            }
            pivots.append(chunkPivot)
        }
        return .ok(pivots.joined(separator: " "), chunks: pieces.count)
    }

    /// Один вызов модели на чанк: max_tokens = слова×3 (кап 90), temp 0,
    /// P1 последовательно (sophie_presence §5).
    /// Пользовательский промпт пивота — ЕДИНСТВЕННОЕ, что уходит модели
    /// сверх статического системного шаблона. Никакой истории чата,
    /// суммариев и предыдущих сообщений здесь нет по построению —
    /// закреплено тестом pivotPromptSeesOnlyOneMessage (СРОЧНО 31.07).
    static func pivotChunkPrompt(piece: String, extra: String) -> String {
        extra + "RU: " + piece + "\nEN:"
    }

    private static func pivotForChunk(_ piece: String, extra: String,
                                      system: String) async -> String? {
        let request = LLMRequest(
            prompt: pivotChunkPrompt(piece: piece, extra: extra),
            systemPrompt: system,
            maxTokens: min(90, max(24, wordCount(piece) * 3)),
            samplingOverride: .extraction)
        do {
            let response = try await ModelScheduler.shared
                .withProvider(.outgoing) { try await $0.generate(request) }
            // внутри чанка перевод строки — не стоп, а пробел
            return response.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        } catch {
            return nil
        }
    }

    // MARK: Санитайзер — порт sanitize_pivot (pipeline.py)

    private static let numWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Детерминированная страховка после модели: первая строка, префиксы
    /// EN:/pivot:, NAME:→name_, числительные→цифры (с составными:
    /// twenty five → 25), kg/km→полные слова, am/pm→маркеры, выдуманный
    /// snake_case→слова. Валидные коды словаря и name_ не трогаются.
    static func sanitize(_ raw: String, codec: RMCodec) -> String {
        var p = raw.split(separator: "\n", maxSplits: 1,
                          omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        for prefix in ["en:", "EN:", "En:", "pivot:", "Pivot:", "PIVOT:"] {
            if p.hasPrefix(prefix) {
                p = String(p.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        p = p.replacingOccurrences(of: "NAME:", with: "name_")
            .replacingOccurrences(of: "Name:", with: "name_")
            .replacingOccurrences(of: "name:", with: "name_")

        // Токены той же грамматикой, что python: [A-Za-z_']+|\d+
        var toks: [String] = []
        var current = ""
        var currentIsDigit = false
        func flush() { if !current.isEmpty { toks.append(current); current = "" } }
        for ch in p {
            let isWord = ch.isLetter && ch.isASCII || ch == "_" || ch == "'"
            let isDigit = ch.isNumber && ch.isASCII
            if isWord {
                if currentIsDigit { flush() }
                currentIsDigit = false; current.append(ch)
            } else if isDigit {
                if !currentIsDigit { flush() }
                currentIsDigit = true; current.append(ch)
            } else if ch == "." || ch == "?" || ch == "!" {
                flush()
                toks.append(String(ch))   // границы предложений v1.1
            } else { flush() }
        }
        flush()

        var out: [String] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t == "." || t == "?" || t == "!" {
                out.append(t)          // границы предложений v1.1
                i += 1
                continue
            }
            if t.hasPrefix("name_") {
                out.append("name_" + t.dropFirst(5))
                i += 1
                continue
            }
            let low = t.lowercased()
            if var value = numWords[low] {
                // составные: twenty five -> 25
                if value % 10 == 0, (20...90).contains(value), i + 1 < toks.count,
                   let unitsDigit = numWords[toks[i + 1].lowercased()],
                   unitsDigit < 10 {
                    value += unitsDigit
                    i += 1
                }
                out.append(String(value))
                i += 1
                continue
            }
            if low == "rur" { i += 1; continue }   // мусор STT от «руб»
            if low == "kg" { out.append("kilogram"); i += 1; continue }
            if low == "km" { out.append("kilometer"); i += 1; continue }
            if low == "pm" || low == "am" {
                out.append(low + "_marker"); i += 1; continue
            }
            if low.contains("_") {
                let entryLayer = codec.byEn[low].flatMap { codec.entries[$0]?.layer }
                // Выдуманный snake_case ИЛИ имя protected-кода (П1: protected
                // недостижим из чата) — расщепить в обычные слова
                if entryLayer == nil || entryLayer == "protected" {
                    out.append(contentsOf: low.split(separator: "_").map(String.init))
                    i += 1
                    continue
                }
            }
            out.append(low)
            i += 1
        }
        return out.joined(separator: " ")
    }
}
