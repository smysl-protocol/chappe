//
//  PivotMatcherTests.swift
//  RMTests
//
//  Фаза B: матчер пивота обязан давать те же юниты, что python
//  (units_from_pivot) — эталон matcher_reference.json генерирует
//  tools/semdict/gen_matcher_reference.py (корпуса + регрессия). Сверяем юниты,
//  байты кодека hex-в-hex и разворот.
//

import Foundation
import Testing
@testable import Chappe

private func referenceData() throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("matcher_reference.json")
    return try Data(contentsOf: url)
}

struct PivotMatcherTests {

    /// ГЛАВНЫЙ ТЕСТ: все эталонные пивоты — юниты и байты как у python.
    @Test func referencePivotsMatchPython() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let json = try JSONSerialization.jsonObject(with: referenceData())
            as! [String: Any]

        for vector in json["vectors"] as! [[String: Any]] {
            let pivot = vector["pivot"] as! String
            let expectedUnits = (vector["units"] as! [[Any]]).map { pair -> RMCodec.Unit in
                switch pair[0] as! String {
                case "code": .code(pair[1] as! Int)
                case "num": .num(pair[1] as! Int)
                case "amount":
                    .amount((pair[1] as! [Any])[0] as! Int,
                            (pair[1] as! [Any])[1] as! String)
                case "time": .time(pair[1] as! Int)
                case "phrase": .phrase(pair[1] as! Int)
                case "emoji": .emoji(pair[1] as! String)
                case "ext": .ext(pair[1] as! Int)
                case "lit": .lit(pair[1] as! String)
                default: .name(pair[1] as! String)
                }
            }

            let units = matcher.units(fromPivot: pivot)
            #expect(units == expectedUnits,
                    "«\(pivot)»:\n swift: \(units)\n python: \(expectedUnits)")

            let hex = try codec.encode(units)
                .map { String(format: "%02x", $0) }.joined()
            #expect(hex == vector["hex"] as! String, "байты разошлись: «\(pivot)»")

            #expect(codec.render(units) == vector["rendered"] as! String,
                    "разворот разошёлся: «\(pivot)»")
        }
    }

    /// Правила матчера по отдельности.
    @Test func matcherRules() throws {
        let matcher = try #require(PivotMatcher.shared)
        let codec = try #require(RMCodec.shared)

        // Числа → num
        #expect(matcher.units(fromPivot: "in 20 minutes")
            .contains(.num(20)))

        // name_ → name с капитализацией
        #expect(matcher.units(fromPivot: "this is name_mark")
            .contains(.name("Mark")))

        // Непокрытая тарабарщина — lit-прогон одним куском
        let units = matcher.units(fromPivot: "xyzzy quux")
        #expect(units == [.lit("xyzzy quux")], "юниты: \(units)")

        // Лемматизация: неправильный глагол
        #expect(PivotMatcher.lemmaCandidates("went").contains("go"))
        #expect(PivotMatcher.lemmaCandidates("coming").contains("come"))
        #expect(PivotMatcher.lemmaCandidates("cities").contains("city"))

        // Фраза раньше одиночек: "do not worry" — один код, не три
        let worry = matcher.units(fromPivot: "do not worry")
        #expect(worry == [.code(codec.byEn["do not worry"]!)], "юниты: \(worry)")
    }
}

/// Ферма 28.07: живой материал с потерянными фактами — регрессия
/// матчера на 12 представительных входах (tests/farm_fixtures_*.json).
/// Паритет с python: юниты, байты, рендер.
struct FarmFixturesTests {
    @Test func farmFixturesMatchPython() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/farm_fixtures_2026-07-28.json")
        let fixtures = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [[String: Any]]
        #expect(fixtures.count == 12)
        for f in fixtures {
            let pivot = f["pivot"] as! String
            let units = matcher.units(fromPivot: pivot)
            let hex = try codec.encode(units)
                .map { String(format: "%02x", $0) }.joined()
            #expect(hex == f["blob_hex"] as! String,
                    Comment(rawValue: "байты разошлись: \(pivot.prefix(50))"))
            #expect(codec.render(units) == f["rendered"] as! String)
        }
    }
}

/// Ф2 v1.1: фразы-ритуалы через esc_local — длиннейшее совпадение,
/// «привет» и «привет как дела» не конкурируют.
struct RitualPhrasesTests {
    @Test func ritualsEncodeAsPhrases() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        // одиночное приветствие — словарный код, не фраза
        #expect(matcher.units(fromPivot: "hi") == [.code(codec.byEn["hi"]!)])
        // «привет как дела» — словарные hi + how are you, конкуренции нет
        #expect(matcher.units(fromPivot: "hi how are you")
                == [.code(codec.byEn["hi"]!),
                    .code(codec.byEn["how are you"]!)])
        // ритуалы v1.1 — phrase-юниты, длиннейшее окно
        let units = matcher.units(fromPivot: "good evening i am in place")
        #expect(units == [.phrase(0), .phrase(5)],
                Comment(rawValue: "\(units)"))
        // roundtrip и рендер обоих языков
        let blob = try codec.encode(units)
        #expect(try codec.decode(blob) == units)
        #expect(codec.render(units) == "Добрый вечер я на месте")
        #expect(codec.render(units, lang: "en") == "Good evening i am in place")
    }

    /// Стража дублей: match-окна фраз v1.1 не смеют совпадать со
    /// словарными статьями (смысл = сумме кодов — не заводим).
    @Test func phraseWindowsDoNotDuplicateDictionary() throws {
        let codec = try #require(RMCodec.shared)
        for (_, p) in codec.phrases {
            for window in p.match {
                #expect(codec.byEn[window] == nil,
                        Comment(rawValue: "дубль со словарём: «\(window)»"))
            }
        }
    }
}

/// Б4-Б6 (живой прогон 29.07): усилитель, идиомы, вопрос без знака.
struct FieldBugsTests {
    @Test func percentAsEmphasisNotQuantity() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        // «сто процентов приду» — усилитель
        let sure = codec.render(matcher.units(
            fromPivot: "100 percent i will come.", allowProtected: false))
        #expect(sure.contains("Точно"), Comment(rawValue: sure))
        #expect(!sure.contains("100"), Comment(rawValue: sure))
        // «двести дирхам» обязано остаться суммой
        let money = matcher.units(fromPivot: "take 200 dirhams",
                                  allowProtected: false)
        #expect(money.contains(.amount(200, "AED")))
        // измеримый контекст — число остаётся числом
        let battery = codec.render(matcher.units(
            fromPivot: "battery is 100 percent", allowProtected: false))
        #expect(battery.contains("100"), Comment(rawValue: battery))
    }

    @Test func idiomsNeverWordByWord() throws {
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(fromPivot: "it turned out large",
                                  allowProtected: false)
        #expect(units.contains(.lit("turned out")),
                Comment(rawValue: "\(units)"))
    }

    @Test func questionStructureGetsMark() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let q = codec.render(matcher.units(
            fromPivot: "how did you copy me", allowProtected: false))
        #expect(q.hasSuffix("?"), Comment(rawValue: q))
        // не-вопрос без знака не получает ложный знак
        let s = codec.render(matcher.units(
            fromPivot: "we are fine", allowProtected: false))
        #expect(!s.hasSuffix("?"), Comment(rawValue: s))
    }
}

/// П4/П5 (дорожный прогон): зацикливание схлопывается, длительность
/// не превращается во время суток.
struct RoadBugsTests {
    @Test func loopedRepeatCollapses() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let r = codec.render(matcher.units(fromPivot:
            "he needs help needs help needs help needs help come fast.",
            allowProtected: false))
        #expect(!r.contains("помощь нужды помощь"), Comment(rawValue: r))
        // легальный двойной повтор живёт
        let d = codec.render(matcher.units(fromPivot: "very very good.",
                                           allowProtected: false))
        #expect(d.lowercased().contains("очень очень"), Comment(rawValue: d))
    }

    @Test func durationIsNotClockTime() {
        // STT-форматтер пишет «на 02:00» — разборка возвращает длительность
        #expect(STTNormalizer.normalizeTimes("бензина на 02:00")
                == "бензина на 2 часа")
        #expect(STTNormalizer.normalizeTimes("воды на сутки")
                == "воды на сутки")
        // время суток с «в» — не трогается
        #expect(STTNormalizer.normalizeTimes("встречаемся в 02:00")
                == "встречаемся в 02:00")
        #expect(STTNormalizer.normalizeTimes("ждём до темноты")
                == "ждём до темноты")
    }
}
