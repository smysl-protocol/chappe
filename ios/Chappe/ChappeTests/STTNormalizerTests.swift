import Foundation
import Testing
@testable import Chappe

// ============================================================================
// П5: длительность vs время суток; П4: обращения в словаре.
// ============================================================================

nonisolated struct STTNormalizerTests {

    @Test("Длительность остаётся длительностью")
    func durationStaysDuration() {
        // словами — не трогаем
        #expect(STTNormalizer.normalizeTimes("ждём уже два часа он молчит")
                == "ждём уже два часа он молчит")
        // Ч:00 от STT в контексте длительности — разбирается обратно
        #expect(STTNormalizer.normalizeTimes("мы ждём его уже 02:00 он не отвечает")
                == "мы ждём его уже 2 часа он не отвечает")
        #expect(STTNormalizer.normalizeTimes("сидим 03:00 подряд без связи")
                == "сидим 3 часа подряд без связи")
    }

    @Test("Составное время собирается только при маркерах часа")
    func clockAssemblyNeedsHourMarker() {
        #expect(STTNormalizer.normalizeTimes("встретимся в семь тридцать у кафе")
                == "встретимся в 07:30 у кафе")
        #expect(STTNormalizer.normalizeTimes("приду к восемь сорок пять")
                == "приду к 08:45")
        #expect(STTNormalizer.normalizeTimes("в 7 30 возьми хлеб")
                == "в 07:30 возьми хлеб")
        // без маркера часа ничего не собираем
        #expect(STTNormalizer.normalizeTimes("семь тридцать не трогаем")
                == "семь тридцать не трогаем")
    }

    @Test("Ф1.1: предлоги длительности — Ч:00 разбирается, время суток живёт")
    func durationPrepositionsFixtures() {
        // Фикстуры брифа 30.07 — вход такой, каким его отдаёт STT
        // (бенч на железе: «за четыре часа» → «за 04:00»)
        #expect(STTNormalizer.normalizeTimes("дошли до перевала за 04:00")
                == "дошли до перевала за 4 часа")
        #expect(STTNormalizer.normalizeTimes("буду через 02:00 примерно")
                == "буду через 2 часа примерно")
        #expect(STTNormalizer.normalizeTimes("бензина на 02:00 осталось")
                == "бензина на 2 часа осталось")
        #expect(STTNormalizer.normalizeTimes("сделаем в течение 02:00")
                == "сделаем в течение 2 часов")
        // «воды на сутки» — нет цифр, не трогаем
        #expect(STTNormalizer.normalizeTimes("воды на сутки хватит")
                == "воды на сутки хватит")
        // время суток ОБЯЗАНО остаться временем суток
        #expect(STTNormalizer.normalizeTimes("встречаемся в 02:00 у моста")
                == "встречаемся в 02:00 у моста")
        #expect(STTNormalizer.normalizeTimes("собрание в 14:30 не опаздывай")
                == "собрание в 14:30 не опаздывай")
        // минуты: «через 00:40» → «через 40 минут»
        #expect(STTNormalizer.normalizeTimes("выезжаем через 00:40")
                == "выезжаем через 40 минут")
        // после пунктуатора терминал приклеен к клок-форме — переживаем
        #expect(STTNormalizer.normalizeTimes("дошли за 04:00. Погода злая.")
                == "дошли за 4 часа. Погода злая.")
    }

    @Test("«через 40 минут» и прочее — как было")
    func unrelatedTextUntouched() {
        for s in ["мы выезжаем через 40 минут наверное",
                  "возьми 3 бутылки воды и хлеб",
                  "батарея 15 процентов осталось",
                  "в семь выходим"] {   // час без минут — не собираем
            #expect(STTNormalizer.normalizeTimes(s) == s, Comment(rawValue: s))
        }
    }

    // MARK: П4 — обращения в словаре

    @Test("Тест-4: «солнышко» доезжает кодом и разворачивается")
    func endearmentsSurviveInDictionary() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        // худший пивот тест-4 после петли
        let units = matcher.units(fromPivot: "sunshine i miss you so much",
                                  allowProtected: false)
        let hasSunshine = units.contains {
            if case .code(let code) = $0 {
                return codec.entries[code]?.en == "sunshine"
            }
            return false
        }
        #expect(hasSunshine, "sunshine обязан быть кодом: \(units)")
        let rendered = codec.render(units)
        #expect(rendered.lowercased().contains("солнышко"), "\(rendered)")

        // остальные обращения на месте
        for (en, ru) in [("darling", "дорогая"), ("honey", "милая"),
                         ("sweetheart", "родная"), ("buddy", "дружище")] {
            let code = try #require(codec.byEn[en], Comment(rawValue: en))
            #expect(codec.entries[code]?.ru == ru)
        }
    }
}
