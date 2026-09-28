//
//  SophieClockTests.swift
//  RMTests
//
//  Ф6 (30.07.2026): дата, время и день недели — данные ОС, не предмет
//  генерации. Живой баг: верное время, но выдуманное «5 апреля,
//  пятница» на вопрос о числе; «пятница» для четверга (30.07.2026)
//  дважды, даже после поправок.
//

import Foundation
import Testing
@testable import Chappe

struct SophieClockTests {

    /// Фиксированный «сейчас»: четверг, 30 июля 2026, 08:08, GMT+7.
    private static let tz = TimeZone(secondsFromGMT: 7 * 3600)!
    private static var now: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 30
        comps.hour = 8; comps.minute = 8
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: comps)!
    }

    // MARK: Строка данных устройства

    /// День недели в строке — из Calendar: 30.07.2026 — четверг.
    @Test func nowLineCarriesCalendarWeekday() {
        let line = SophieClock.nowLine(now: Self.now, timeZone: Self.tz)
        #expect(line.contains("четверг"))
        #expect(line.contains("30 июля 2026"))
        #expect(line.contains("08:08"))
        #expect(line.contains("GMT+7"))
        #expect(line.contains("единственный источник"))
    }

    // MARK: Перехват до модели

    /// Вопросы о числе/дне/времени отвечает код — модель не нужна.
    @Test func clockQuestionsAnsweredByCode() {
        let date = SophieClock.directAnswer(for: "Какое сегодня число?",
                                            now: Self.now, timeZone: Self.tz)
        #expect(date == "Сегодня четверг, 30 июля 2026.")

        let weekday = SophieClock.directAnswer(for: "какой день недели",
                                               now: Self.now, timeZone: Self.tz)
        #expect(weekday == "Сегодня четверг.")

        let time = SophieClock.directAnswer(for: "Сколько времени?",
                                            now: Self.now, timeZone: Self.tz)
        #expect(time == "Сейчас 08:08 (часовой пояс GMT+7).")

        #expect(SophieClock.directAnswer(for: "который час",
                                         now: Self.now, timeZone: Self.tz) != nil)
    }

    /// НЕ перехватывается: вопросы, где время/число — не о часах.
    @Test func nonClockQuestionsGoToModel() {
        for question in ["сколько времени идти до Убуда",
                         "сколько времени займёт дорога",
                         "какое число тебе нравится",
                         "расскажи про наш поход",
                         "какой сегодня план",
                         "сколько времени нужно на сборку рюкзака"] {
            #expect(SophieClock.directAnswer(for: question,
                                             now: Self.now,
                                             timeZone: Self.tz) == nil,
                    "перехвачен чужой вопрос: «\(question)»")
        }
    }

    // MARK: Пост-валидатор

    /// Живой кейс: «пятница» для 30 июля 2026 — Calendar говорит
    /// четверг, гейт подменяет и фиксирует расхождение.
    @Test func weekdayNextToDateIsRecomputed() {
        let gated = SophieClock.validated("Сегодня 30 июля 2026, пятница.",
                                          now: Self.now, timeZone: Self.tz)
        #expect(gated.text == "Сегодня 30 июля 2026, четверг.")
        #expect(gated.mismatches.count == 1)
    }

    /// День недели считается для УПОМЯНУТОЙ даты, не для сегодняшней:
    /// 5 апреля 2026 — воскресенье.
    @Test func weekdayForMentionedDateUsesThatDate() {
        let gated = SophieClock.validated(
            "Встреча была 5 апреля 2026, пятница, у пирса.",
            now: Self.now, timeZone: Self.tz)
        #expect(gated.text.contains("воскресенье"))
        #expect(!gated.text.contains("пятница"))
    }

    /// «Сегодня» + выдуманная дата → подмена настоящей.
    @Test func todayWithWrongDateIsReplaced() {
        let gated = SophieClock.validated("Сегодня 5 апреля.",
                                          now: Self.now, timeZone: Self.tz)
        #expect(gated.text == "Сегодня 30 июля 2026.")
        #expect(gated.mismatches.count == 1)
    }

    /// «Сейчас HH:MM»: минутный дрейф прощается, враньё — нет.
    @Test func nowTimeToleratesMinutesButNotHours() {
        let ok = SophieClock.validated("Сейчас 08:09, скоро рассвет.",
                                       now: Self.now, timeZone: Self.tz)
        #expect(ok.text.contains("08:09"))
        #expect(ok.mismatches.isEmpty)

        let bad = SophieClock.validated("Сейчас 12:40.",
                                        now: Self.now, timeZone: Self.tz)
        #expect(bad.text == "Сейчас 08:08.")
        #expect(bad.mismatches.count == 1)
    }

    /// Исторические даты без дня недели рядом не трогаются:
    /// рассказ про март 1791 года — не повод для подмен.
    @Test func historicalDatesUntouched() {
        let text = "Первое сообщение передали 2 марта 1791 года между "
                 + "Брюлоном и Парсе."
        let gated = SophieClock.validated(text, now: Self.now,
                                          timeZone: Self.tz)
        #expect(gated.text == text)
        #expect(gated.mismatches.isEmpty)
    }

    /// День недели без даты и без «сегодня/сейчас» — не трогаем:
    /// «в пятницу пойдём к пирсу» может быть про любую пятницу.
    @Test func bareWeekdayPlansUntouched() {
        let text = "В пятницу пойдём к пирсу за лодкой."
        let gated = SophieClock.validated(text, now: Self.now,
                                          timeZone: Self.tz)
        #expect(gated.text == text)
        #expect(gated.mismatches.isEmpty)
    }

    /// Падежная форма при замене сохраняется: «в пятницу» → «в четверг»
    /// (винительный), «пятница» → «четверг» (именительный).
    @Test func replacementKeepsGrammaticalCase() {
        let gated = SophieClock.validated(
            "Сегодня 30 июля 2026 — в пятницу и пойдём.",
            now: Self.now, timeZone: Self.tz)
        #expect(gated.text.contains("в четверг"))
    }
}
