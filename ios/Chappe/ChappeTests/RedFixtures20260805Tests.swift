import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Красные фикстуры замера живого корпуса 05.08 — все 19 кандидатов
// (tests/live_corpus/red_candidates_2026-08-05.json, решение владельца:
// «все девятнадцать — в красные фикстуры, до починки»).
//
// Детерминизм без LLM: берётся ЗАПИСАННЫЙ пивот из замера, дальше —
// продовый хвост конвейера: sanitize → PivotMatcher → кодек → гейты.
// Ожидание извне (правило 4): вход и пивот — литералы из замера,
// не выведенные из кода.
//
// Непочиненный кандидат обёрнут withKnownIssue: тест ДОКАЗЫВАЕТ, что
// дефект воспроизводится (не воспроизвёлся — тест падает «unexpected
// pass»), а после починки withKnownIssue снимается и тест становится
// обычным замком.
//
// 11.08: замок round-trip (docs/reports/semantic_roundtrip_gate.md)
// погасил ВЕСЬ класс лоссовых исходов — декод ≠ вводу теперь уходит
// текстом и до человека не доезжает. Все withKnownIssue этого файла
// сняты: дефекты перестали воспроизводиться ПО ПОСТРОЕНИЮ (замок
// первым в finish), позитивные ожидания остались замками — сломай
// round-trip-гейт, и они покраснеют. Ограничение омонимов в словаре
// никуда не делось (homonyms_2026-08-05.md), но наружу больше не течёт.
// ============================================================================

nonisolated struct RedFixtures20260805Tests {

    private var codec: RMCodec { RMCodec.shared! }
    private var matcher: PivotMatcher { PivotMatcher.shared! }

    /// Продовый хвост конвейера от записанного пивота.
    private func tail(source: String, recordedPivot: String)
    -> (units: [RMCodec.Unit], rendered: String, pivot: String) {
        let pivot = SemanticEncoder.sanitize(recordedPivot, codec: codec)
        let units = matcher.units(fromPivot: pivot, allowProtected: false)
        return (units, codec.render(units), pivot)
    }

    /// Терминальная логика prepare без LLM: гейты → спасение → finish.
    /// Возвращает, ушло бы сообщение текстом, и рендер/юниты исхода.
    private func finalOutcome(source: String, recordedPivot: String)
    -> (isText: Bool, rendered: String, units: [RMCodec.Unit]) {
        let t = tail(source: source, recordedPivot: recordedPivot)
        guard !t.units.isEmpty,
              let blob = try? codec.encode(t.units) else {
            return (true, "", [])
        }
        let encoded = SemanticEncoder.Encoded(
            pivotRaw: recordedPivot, pivot: t.pivot, units: t.units,
            blob: blob, rendered: t.rendered)
        func finished(_ e: SemanticEncoder.Encoded)
        -> (Bool, String, [RMCodec.Unit]) {
            if case .text = SemanticEncoder.finish(e, source: source) {
                return (true, e.rendered, e.units)
            }
            return (false, e.rendered, e.units)
        }
        let gated = SemanticEncoder.negationGateReason(
                        source: source, rendered: t.rendered) != nil
            || SemanticEncoder.entityGateReason(
                        source: source, pivot: t.pivot, codec: codec) != nil
        if gated {
            if let mixed = SemanticEncoder.mixedRescue(
                    source: source, encoded: encoded, codec: codec) {
                return finished(mixed)
            }
            return (true, t.rendered, t.units)
        }
        return finished(encoded)
    }

    /// Содержательные слова источника (≥4 букв, не служебные),
    /// представленные в юнитах (кодовый рендер + литералы) хотя бы
    /// префиксом. Мера полноты для фикстуры испарения.
    private func contentCoverage(source: String,
                                 units: [RMCodec.Unit]) -> Double {
        let stop: Set<String> = ["привет", "пожалуйста", "здравствуйте"]
        let words = source.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 && !stop.contains($0) }
        guard !words.isEmpty else { return 1 }
        let haystack = (codec.render(units) + " " + units.compactMap {
            if case .lit(let s) = $0 { return s } else { return nil }
        }.joined(separator: " ")).lowercased()
        let hit = words.filter { haystack.contains(String($0.prefix(4))) }
        return Double(hit.count) / Double(words.count)
    }

    // ------------------------------------------------------------------
    // 1. Испарение содержания (#768) — чинится первым (решение владельца)
    // ------------------------------------------------------------------

    @Test("#768: вопрос не смеет испаряться — полнота или отказ")
    func q768ContentMustNotVanish() {
        // ПОЧИНЕНО 05.08: гейт пропажи в finish() + хвост без букв
        let source = "Всем привет) подскажите пожалуйста в Чангу куда "
                   + "можно завтра сходить на йогу ?)"
        let recorded = "hello everyone . where can you go in changzhou "
                     + "for yoga tomorrow ?"
        let o = finalOutcome(source: source, recordedPivot: recorded)
        #expect(o.isText
                || contentCoverage(source: source, units: o.units) >= 0.5,
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    @Test("#768: хвост без букв — не предложение для спасения")
    func q768TailIsNotASentence() {
        // ПОЧИНЕНО 05.08: splitSentences приклеивает хвост без букв
        let sents = SemanticEncoder.splitSentences(
            "Всем привет) подскажите в Чангу куда сходить на йогу ?)")
        #expect(sents.allSatisfy {
            $0.rangeOfCharacter(from: .letters) != nil
        }, Comment(rawValue: "предложение без единой буквы: \(sents)"))
    }

    // ------------------------------------------------------------------
    // 2. Пропажа сущностей — гейт ловит добавленное, не потерянное (#5)
    // ------------------------------------------------------------------

    @Test("#5: «уважаемая лошадь» пропала — гейт пропажи отбивает")
    func q5DroppedNounMustBeCaught() {
        // ПОЧИНЕНО 05.08: двусторонняя проверка (missingNounGateReason)
        let source = "правда он не красивый? уважаемая лошадь"
        let recorded = "true he is not handsome ? honey"
        let o = finalOutcome(source: source, recordedPivot: recorded)
        #expect(o.isText, Comment(rawValue: "исход: \(o.rendered)"))
    }

    // ------------------------------------------------------------------
    // 3. Числа и время из ниоткуда в рендере (#633, #3631)
    // ------------------------------------------------------------------

    @Test("#633: «Бедный 1» — число из ниоткуда отбито")
    func q633FabricatedDigit() {
        // ПОЧИНЕНО 05.08: гейт чисел рендера (fabricatedNumberReason)
        let source = "бедная. это вы ее ?"
        let recorded = "poor 1 . is this you ?"
        let o = finalOutcome(source: source, recordedPivot: recorded)
        #expect(o.isText || !o.rendered.contains("1"),
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    @Test("#3631: «до полудня» из «am» — сфабрикованное время")
    func q3631FabricatedTime() {
        let source = "Я собираюсь в убуд в субботу"
        let recorded = "i am_marker going to ubud on saturday ."
        let o = finalOutcome(source: source, recordedPivot: recorded)
        // 11.08: гаснет замком round-trip — сфабрикованное время не
        // доезжает (исход текст); сломай замок — тест красный
        #expect(o.isText || !o.rendered.lowercased().contains("полудня"),
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    // ------------------------------------------------------------------
    // 4. Омонимы EN-пивота — легальный спан, гейт бессилен.
    //    Решение владельца: описать как ограничение, НЕ реализовывать.
    //    Описание: docs/reports/homonyms_2026-08-05.md
    // ------------------------------------------------------------------

    private static let homonymsSick: [(seq: Int, source: String,
                                       pivot: String, poison: String)] = [
        (2313, "Нам сегодня не продали. Пришлось бегать,местных просить "
             + "заплатить. Но никто не отказал. И с нас не попросили "
             + "деньги. Добрые люди",
         "we didn't buy anything today . had to run around asking locals "
             + "to pay . but nobody refused . no money asked . kind people",
         "вид люди"),
        (1425, "граб 280 с чем то был, месяц назад",
         "grab 280 was there a month ago .", "возьми"),
        (5625, "Можно ли заказать два байк такси одновременно через grab ?",
         "can you order 2 bike taxis at the same time through grab ?",
         "возьми"),
        (3928, "так а чего не так?", "so what is not right ?", "направо"),
        (5202, "не врите взяли наверное уже",
         "don't lie we probably already took it .", "врать"),
    ]

    @Test("омонимы пивота: слово прослежено, смысл перевран",
          arguments: homonymsSick.map(\.seq))
    func homonymRenders(seq: Int) throws {
        let c = try #require(Self.homonymsSick.first { $0.seq == seq })
        let o = finalOutcome(source: c.source, recordedPivot: c.pivot)
        // 11.08: словарная разметка омонимов не делалась (ограничение
        // остаётся, homonyms_2026-08-05.md), но замок round-trip гасит
        // исход — отравленный рендер не доезжает до человека
        #expect(o.isText || !o.rendered.lowercased().contains(c.poison),
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    @Test("омонимы, пойманные гейтом пропажи побочно: #901, #1601")
    func homonymsCaughtByLossGate() {
        // «бронью»→armor и «отдыха»→break теряли слово источника —
        // двусторонняя проверка отбивает такие рендеры в текст
        let cases: [(String, String)] = [
            ("Кто-то проскакивает с бронью. Но тут как говорится …",
             "someone is skipping with armor . but here as they say . . ."),
            ("Добрый день! Подскажите, пожалуйста, как погода для "
             + "отдыха в конце октября?",
             "good day please tell me the weather for a break in late "
             + "october"),
        ]
        for (source, recorded) in cases {
            let o = finalOutcome(source: source, recordedPivot: recorded)
            #expect(o.isText, Comment(rawValue: "исход: \(o.rendered)"))
        }
    }


    // ------------------------------------------------------------------
    // 5. Салат словарных слов проходит финальный гейт (#968)
    // ------------------------------------------------------------------

    @Test("#968: салат словарных слов — 100% словарность, ноль смысла")
    func q968WordSalad() {
        let source = "Ну там не мало топать от того места где высаживают "
                   + "до шляпы этой"
        let recorded = "not far from the drop off point to the hat place ."
        let o = finalOutcome(source: source, recordedPivot: recorded)
        // 11.08: связность по-прежнему ничем не меряется, но салат не
        // round-trip — замок отправляет текстом
        #expect(o.isText, Comment(rawValue: "исход: \(o.rendered)"))
    }

    // ------------------------------------------------------------------
    // 6. Разговорные обороты и мелкие настоящие
    // ------------------------------------------------------------------

    @Test("#1283: «не ну угоняют» инвертирован в «Не украсть»")
    func q1283ColloquialNegation() {
        let source = "не ну угоняют . вы ж наверное ключик там оставили"
        let recorded = "not stealing . you probably left the key there ."
        let o = finalOutcome(source: source, recordedPivot: recorded)
        // 11.08: гейт отрицаний «не ну» так и не понимает, но замок
        // round-trip гасит инверсию — исход текст
        #expect(o.isText
                || !o.rendered.lowercased().contains("не украсть"),
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    @Test("#1555: сленг «канеш» становится именем Kanesh")
    func q1555SlangBecomesName() {
        let source = "есть канеш. гугло карта все знает"
        let recorded = "name_kanesh . google map knows everything ."
        let o = finalOutcome(source: source, recordedPivot: recorded)
        // 11.08: транслит-трассировка всё ещё легализует NAME, но
        // Kanesh не round-trip — замок отправляет текстом
        let hasName = o.units.contains { u in
            if case .name = u { return true } else { return false }
        }
        #expect(o.isText || !hasName,
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    @Test("#2470: «я согласна» → «Я согласен» — род потерян")
    func q2470GenderLost() {
        let source = "Да, тут я согласна. Пока так и планирую, но попытать "
                   + "удачу тоже стоит)) вот и узнаю на всякий случай"
        let recorded = "yes i agree . i'll keep it as planned but trying "
                     + "luck also makes sense just in case ."
        let o = finalOutcome(source: source, recordedPivot: recorded)
        // 11.08: развёртка agree рода не знает и не узнала, но
        // «Я согласен» ≠ вводу — замок отправляет текстом
        #expect(o.isText || !o.rendered.contains("согласен"),
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    @Test("пометки словаря протекают в рендер: «(крест)», «(лежать)»",
          arguments: [113, 5202, 968])
    func annotationLeaks(seq: Int) {
        let cases: [Int: (String, String)] = [
            113: ("Только обменники после пересечения границы. Вы "
                  + "планируете ее пересекать?",
                  "only exchange offices after crossing the border . "
                  + "do you plan to cross it ?"),
            5202: ("не врите взяли наверное уже",
                   "don't lie we probably already took it ."),
            968: ("Ну там не мало топать от того места где высаживают "
                  + "до шляпы этой",
                  "not far from the drop off point to the hat place ."),
        ]
        let (source, recorded) = cases[seq]!
        let o = finalOutcome(source: source, recordedPivot: recorded)
        // 11.08: пометки из ru-колонки словарь так и отдаёт, но рендер
        // с «(крест)» не round-trip — замок отправляет текстом
        let leaked = o.rendered.contains("(") && !source.contains("(")
        #expect(o.isText || !leaked,
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    @Test("#2119: «на чай ему дадите» — исковерканный смысл отбит")
    func q2119TeaTip() {
        // Закрыт побочно гейтом пропажи (слово источника не выжило)
        let source = "В крайнем случае, на чай  ему дадите. Вам так и так "
                   + "в обменник надо."
        let recorded = "in case of emergency give him tea . you need to "
                     + "go to the exchange anyway ."
        let o = finalOutcome(source: source, recordedPivot: recorded)
        let literalTea = o.rendered.contains("чай")
            && !o.rendered.contains("на чай")
        #expect(o.isText || !literalTea,
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    @Test("#2138: «Кому скучно?» → «Кто одиноко?» отбит")
    func q2138BoredLonely() {
        // Закрыт побочно гейтом пропажи
        let source = "Кому скучно ?   Давайте встретимся покатаемся на байки"
        let recorded = "who is lonely ? let's meet ride bikes ."
        let o = finalOutcome(source: source, recordedPivot: recorded)
        #expect(o.isText || !o.rendered.lowercased().contains("одинок"),
                Comment(rawValue: "исход: \(o.rendered)"))
    }

    // ------------------------------------------------------------------
    // 7. #5361 — гейт размера против исходника: ПОЧИНЕНО шагом 0
    //    (замок TextPathSizeGateTests/finishComparesAgainstSource);
    //    здесь — данные кандидата против живого finish().
    // ------------------------------------------------------------------

    @Test("#5361: блоб с именами больше текста — после починки текст")
    func q5361SizeGateFixed() throws {
        let source = "Martha Fang Skin Clinic\n к dr.Martha"
        let recorded = "name_martha fang skin clinic . name_dr . martha"
        let t = tail(source: source, recordedPivot: recorded)
        let blob = try codec.encode(t.units)
        let encoded = SemanticEncoder.Encoded(
            pivotRaw: recorded, pivot: t.pivot, units: t.units,
            blob: blob, rendered: t.rendered)
        if codec.wireBlob(blob).count > TextCodec.best(source).data.count {
            guard case .text = SemanticEncoder.finish(encoded,
                                                      source: source) else {
                Issue.record("блоб больше текста, а finish отдал семантику")
                return
            }
        }
    }
}
