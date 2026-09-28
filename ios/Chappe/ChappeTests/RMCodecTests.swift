//
//  RMCodecTests.swift
//  RMTests
//
//  Фаза A семантического сжатия: Swift-кодек обязан сходиться
//  с tools/semdict/rm_codec_testvectors.json ПОБАЙТОВО (hex-в-hex).
//

import Foundation
import Testing
@testable import Chappe

private func repoData(_ relative: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent(relative))
}

private func parseUnits(_ raw: [[Any]]) -> [RMCodec.Unit] {
    raw.map { pair in
        let kind = pair[0] as! String
        switch kind {
        case "code": return .code(pair[1] as! Int)
        case "num": return .num(pair[1] as! Int)
        case "lit": return .lit(pair[1] as! String)
        case "name": return .name(pair[1] as! String)
        case "amount":
            let payload = pair[1] as! [Any]
            return .amount(payload[0] as! Int, payload[1] as! String)
        case "time": return .time(pair[1] as! Int)
        case "phrase": return .phrase(pair[1] as! Int)
        case "emoji": return .emoji(pair[1] as! String)
        case "ext": return .ext(pair[1] as! Int)
        default: fatalError("неизвестный вид юнита: \(kind)")
        }
    }
}

struct RMCodecTests {

    /// ГЛАВНЫЙ ТЕСТ: все векторы rm_codec_testvectors.json — hex-в-hex.
    @Test func vectorsMatchByteForByte() throws {
        let codec = try #require(RMCodec.shared)
        let json = try JSONSerialization.jsonObject(
            with: repoData("tools/semdict/rm_codec_testvectors.json")) as! [String: Any]
        #expect(json["dict_version"] as? String == codec.version,
                "версия словаря разошлась")

        for vector in json["vectors"] as! [[String: Any]] {
            let units = parseUnits(vector["units"] as! [[Any]])
            let expectedHex = vector["hex"] as! String

            let blob = try codec.encode(units)
            let gotHex = blob.map { String(format: "%02x", $0) }.joined()
            #expect(gotHex == expectedHex,
                    "encode: получилось \(gotHex), ожидалось \(expectedHex)")

            // decode обратно в те же юниты
            let decoded = try codec.decode(blob)
            #expect(decoded == units, "decode разошёлся: \(decoded)")

            // и разворот совпадает с python-рендером
            #expect(codec.render(units) == vector["ru"] as! String)
        }
    }

    /// Round-trip произвольных юнитов, включая крайние varint и UTF-8.
    @Test func roundTripEdgeCases() throws {
        let codec = try #require(RMCodec.shared)
        let cases: [[RMCodec.Unit]] = [
            [],
            [.num(0), .num(127), .num(128), .num(16383), .num(16384), .num(1_000_000)],
            [.lit("привет мир"), .name("Марк"), .lit("x")],
            [.code(codec.escNum == 0 ? 1 : 0)],   // любой валидный код
            [.name("Ёж"), .num(42), .lit("café ☕")],
        ]
        for units in cases {
            let blob = try codec.encode(units)
            #expect(try codec.decode(blob) == units, "units: \(units)")
        }
    }

    /// Битый поток не зацикливается — честная ошибка.
    @Test func corruptStreamThrows() throws {
        let codec = try #require(RMCodec.shared)
        #expect(throws: LLMError.self) {
            _ = try codec.decode([0x05, 0xFF, 0xFF, 0xFF, 0xFF])
        }
    }
}

/// Зеркало получателя: свой блоб через приёмный путь — чистая
/// развёртка таблицей, без петли (п.1 чистки драфта).
struct ReceiverMirrorTests {
    @Test @MainActor func mirrorShowsPureTableRender() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(fromPivot:
            "take 200 dirhams in cash be at the bridge at 9",
            allowProtected: false)
        var entry = ChatEntry(kind: .outgoing,
                              text: "Возьми 200 дирхамов наличными, будь у моста к девяти")
        entry.semanticBlob = codec.wireBlob(try codec.encode(units))

        let mirror = try #require(entry.receiverMirror())
        #expect(mirror == codec.render(units),
                Comment(rawValue: "зеркало обязано быть чистым рендером: \(mirror)"))
        #expect(mirror.contains("200 дирхамов"), Comment(rawValue: mirror))
        // гладкий текст отправителя и зеркало — разные строки: расхождение видно
        #expect(mirror != entry.text)
        // текстовое сообщение зеркала не имеет — дойдёт дословно
        #expect(ChatEntry(kind: .outgoing, text: "просто текст")
            .receiverMirror() == nil)
    }
}

/// Полная валютная таблица (п.3 предзаморозки): алфавитный ISO 4217,
/// индекс в байт, резерв 255 — валюта литералом.
struct CurrencyTableTests {
    @Test func tableIsFrozenAlphabeticalAndFits() {
        #expect(RMCodec.currencies == RMCodec.currencies.sorted(),
                "алфавитный порядок — часть протокола")
        #expect(RMCodec.currencies.count < 255,
                "255 зарезервирован под литерал")
        #expect(Set(RMCodec.currencies).count == RMCodec.currencies.count)
    }

    @Test func exoticAndRawCurrenciesRoundTrip() throws {
        let codec = try #require(RMCodec.shared)
        let units: [RMCodec.Unit] = [
            .amount(50, "MAD"),      // в таблице, индексом
            .amount(7, "XXX"),       // вне таблицы — литеральный резерв
            .amount(200, "AED"),
        ]
        let blob = try codec.encode(units)
        #expect(try codec.decode(blob) == units)
        #expect(codec.render(units).contains("50 MAD"), "экзотика — ISO-кодом")
        #expect(codec.render(units).contains("200 дирхамов"))
    }
}

/// Совместимость версий (п.5): блоб с чужим хешем таблицы — честная
/// заглушка, не мусор и не крэш.
struct VersionSkewTests {
    @Test func foreignTableHashYieldsFallbackStub() throws {
        let codec = try #require(RMCodec.shared)
        let blob = try codec.encode([.num(7), .code(codec.escNum == 0 ? 1 : 0)])
        var wire = codec.wireBlob(blob)
        wire[0] ^= 0xFF   // «отправитель с другой таблицей»

        // приёмный путь: не throw, а текст-заглушка
        let text = try TextCodec.decompress(wire, codec: Envelope.codecSemantic)
        #expect(text.contains("версии словаря"), Comment(rawValue: text))

        // развёртка ленты: тихий откат на сохранённый текст
        #expect(codec.unwrapWire(wire) == nil)
        var entry = ChatEntry(kind: .incoming, text: text)
        entry.semanticBlob = wire
        #expect(entry.displayText(language: "en") == text)
        #expect(entry.receiverMirror() == nil)

        // свой хеш — работает как раньше
        let good = codec.wireBlob(blob)
        #expect(try TextCodec.decompress(good,
                codec: Envelope.codecSemantic).contains("7"))
    }
}

/// Заморозка v1 (п.6): версия, отпечаток таблицы и объём словаря
/// зафиксированы — любое расхождение значит «кто-то пересобрал».
struct DictFreezeV1Tests {
    @Test func frozenDictionaryInvariants() throws {
        let codec = try #require(RMCodec.shared)
        #expect(codec.version == "1.3.0", "версия словаря v1.3")
        #expect(codec.tableHash == 0x883E14BE, "отпечаток провода v1.3 (словарь+litchars), 4 байта")
        #expect(codec.entries.count == 1580, "объём словаря v1.3")
    }
}

/// П.1 пост-фермы: регистр имён — esc_name рендерится с заглавной
/// в любом месте фразы, даже если в блобе строчными.
struct NameCaseTests {
    @Test func namesRenderCapitalizedAnywhere() throws {
        let codec = try #require(RMCodec.shared)
        let meet = try #require(codec.byEn["meet"])
        let units: [RMCodec.Unit] = [.code(meet), .name("марина"),
                                     .code(meet), .name("andrey")]
        let rendered = codec.render(units)
        #expect(rendered.contains("Марина"), Comment(rawValue: rendered))
        #expect(rendered.contains("Andrey"), Comment(rawValue: rendered))
        #expect(!rendered.contains("марина") || rendered.hasPrefix("Марина"))
        // roundtrip сохраняет байты как есть — капитализация только в рендере
        let blob = try codec.encode([.name("tom")])
        #expect(try codec.decode(blob) == [.name("tom")])
    }
}

/// Ф3 v1.1: эмодзи — отдельное пространство [esc_local][0x80][idx].
struct EmojiV11Tests {
    @Test func emojiRoundTripAndRendersAsSymbol() throws {
        let codec = try #require(RMCodec.shared)
        #expect(codec.emojiTable.count == 255, "таблица top-255 заморожена")
        let units: [RMCodec.Unit] = [.phrase(1), .emoji("👍")]
        let blob = try codec.encode(units)
        #expect(try codec.decode(blob) == units)
        // 👍 — символом, НИКОГДА словом «хорошо»
        let rendered = codec.render(units)
        #expect(rendered.contains("👍"), Comment(rawValue: rendered))
        #expect(!rendered.lowercased().contains("хорошо"))
        // реакция «принял 👍» — 8 байт блоба (esc_local 12 бит + два
        // выравнивания); против 12-24 Б текстом — всё ещё 2-3x
        #expect(blob.count <= 8, Comment(rawValue: "\(blob.count) Б"))
    }

    @Test func matcherEmojiInAndOutOfTable() throws {
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(fromPivot: "got it 👍 see you")
        #expect(units.contains(.emoji("👍")), Comment(rawValue: "\(units)"))
        // вне таблицы — литералом, не потерян
        let rare = matcher.units(fromPivot: "look 🦄 here")
        #expect(rare.contains(.lit("🦄")), Comment(rawValue: "\(rare)"))
    }
}

/// Пунктуация v1.1: коды границы + запятые-правила рендера (срочный
/// бриф 29.07). Тесты из брифа: многопредложность, придаточное, языки.
struct PunctuationV11Tests {
    @Test func multiSentenceWithQuestionAndStatement() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(
            fromPivot: "we are not going there. take water! will you come?",
            allowProtected: false)
        let blob = try codec.encode(units)
        #expect(try codec.decode(blob) == units)
        let ru = codec.render(units)
        #expect(ru == "Мы не иду там. Взять вода! Ты приходить?",
                Comment(rawValue: ru))
        let en = codec.render(units, lang: "en")
        #expect(en == "We are not going there. Take water! Will you come?",
                Comment(rawValue: en))
    }

    @Test func conditionalClauseGetsComma() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(
            fromPivot: "call me if the road is closed.",
            allowProtected: false)
        let ru = codec.render(units)
        #expect(ru.contains(", если"), Comment(rawValue: ru))
        // en-правила свои: перед if запятая НЕ ставится
        let en = codec.render(units, lang: "en")
        #expect(!en.contains(", if"), Comment(rawValue: en))
    }

    /// Ф4 закрыта кодами границы: четыре формы различимы рендером,
    /// биты настроения в заголовке не строились (знак — по предложению).
    @Test func fourMoodsViaBoundaryCodes() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        func render(_ pivot: String) -> String {
            codec.render(matcher.units(fromPivot: pivot,
                                       allowProtected: false))
        }
        let statement = render("take water.")
        let question = render("are you taking water?")
        let request = render("please take water.")
        let urgent = render("take water now!")
        #expect(statement.hasSuffix("."), Comment(rawValue: statement))
        #expect(question.hasSuffix("?"), Comment(rawValue: question))
        #expect(request.contains("Пожалуйста") && request.hasSuffix("."),
                Comment(rawValue: request))
        #expect(urgent.hasSuffix("!"), Comment(rawValue: urgent))
        // «возьми воду» и «ты берёшь воду?» обязаны различаться
        #expect(statement != question)
    }
}
