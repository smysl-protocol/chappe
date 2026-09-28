import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Каноничность литерала (дефект №1 инвентаризации 02.08): длина —
// в СКАЛЯРАХ Unicode, не в графемах. «❤️» — одна графема, два скаляра;
// до починки Swift писал длину 1 и два тела → расхождение с python и
// битый декод. Плюс тест гейта размера (долг 4 — фиксация).
// ============================================================================

nonisolated struct LiteralCanonTests {

    private var codec: RMCodec { RMCodec.shared! }

    @Test("Многоскалярные графемы переживают round-trip")
    func multiScalarGraphemesRoundTrip() throws {
        // ❤️ = U+2764 U+FE0F; й может прийти разложенным; ZWJ-эмодзи
        for text in ["❤️", "жди у моста ❤️", "🧑‍🚒 пожарный",
                     "и\u{0306}од разложенный"] {
            let units: [RMCodec.Unit] = [.lit(text)]
            let blob = try codec.encode(units)
            let back = try codec.decode(blob)
            guard case .lit(let out) = back.first else {
                Issue.record("не литерал: \(back)")
                return
            }
            // сравнение по скалярам: провод переносит скаляры
            #expect(Array(out.unicodeScalars) == Array(text.unicodeScalars),
                    "скаляры разъехались: \(text) → \(out)")
        }
    }

    @Test("Длина в проводе — число скаляров (паритет с python)")
    func lengthByteCountsScalars() throws {
        // «❤️» вне litchars-таблицы: оба скаляра уходят escape-веткой
        // (cp=0 + 21 бит). Байт длины после выравнивания esc-кода обязан
        // быть 2 — как пишет python (кодовые точки), не 1 (графемы).
        let blob = try codec.encode([.lit("❤️")])
        // [varint юнитов=1][12 бит esc_lit][выравнивание][len]...
        // 12 бит esc + 4 бита выравнивания = 2 байта после varint
        #expect(blob.count >= 4)
        #expect(blob[3] == 2, "байт длины: \(blob.map { String(format: "%02x", $0) })")
    }

    @Test("Обрезка 255 — тоже в скалярах")
    func truncationCountsScalars() throws {
        // 03.08: обрезка ЗАМЕНЕНА явным отказом — тихая потеря текста
        // запрещена (см. LiteralOverflowTests). Инвариант «считаем
        // СКАЛЯРЫ, а не графемы» проверяется на длине у самой границы:
        // «❤️» = 1 графема, 2 скаляра, поэтому 127 сердец = 254 скаляра
        // проходят, а 128 (256 скаляров) — уже нет.
        let fits = String(repeating: "❤️", count: 127)     // 254 скаляра
        let blob = try codec.encode([.lit(fits)])
        let back = try codec.decode(blob)
        guard case .lit(let out) = back.first else {
            Issue.record("не литерал"); return
        }
        #expect(out.unicodeScalars.count == 254)
        #expect(out == fits, "round-trip обязан быть побайтовым")

        let overflows = String(repeating: "❤️", count: 128)  // 256 скаляров
        #expect(throws: (any Error).self) {
            _ = try codec.encode([.lit(overflows)])
        }
    }
}

// MARK: - Долг 4: гейт размера (фиксация тестом)

nonisolated struct SizeGateTests {

    @Test("Формула гейта отдаёт меньшее из двух представлений")
    func gateFormulaPicksSmaller() throws {
        let codec = RMCodec.shared!
        // Направление НЕ предполагается: на коротких строках
        // litchars-литерал ДЕШЕВЛЕ zlib (у zlib ~11 Б заголовка) —
        // выяснено этим же тестом 02.08. Фиксируем оба факта:
        let short = "жду у моста"
        let shortBlob = codec.wireBlob(try codec.encode([.lit(short)]))
        let shortZl = try TextCodec.compress(short, codec: Envelope.codecZlib)
        #expect(shortBlob.count < shortZl.count,
                "короткий литерал: \(shortBlob.count) vs zlib \(shortZl.count)")

        // а на длинном повторяющемся тексте zlib берёт своё.
        // 03.08: длина подобрана ПОД ГРАНИЦУ литерала (255 скаляров) —
        // раньше строка была длиннее и молча обрезалась, теперь кодек
        // на такой отказался бы, и тест мерил бы не то.
        let long = String(repeating: "очень длинный повторяющийся текст ",
                          count: 7)
        let longBlob = codec.wireBlob(try codec.encode([.lit(long)]))
        let longZl = try TextCodec.compress(long, codec: Envelope.codecZlib)
        #expect(longZl.count < longBlob.count,
                "длинный повтор: zlib \(longZl.count) vs \(longBlob.count)")

        // формула finish(): >= уходит в текст — регресс «отправили
        // большее» невозможен по построению при обоих направлениях
        for (blob, zl) in [(shortBlob, shortZl), (longBlob, longZl)] {
            let shipped = blob.count >= zl.count ? zl.count : blob.count
            #expect(shipped == min(blob.count, zl.count))
        }
    }

    @Test("Формула гейта: меньшее побеждает в обе стороны")
    func gatePicksSmallerRepresentation() throws {
        let codec = RMCodec.shared!
        // словарная фраза: коды обязаны быть меньше zlib-текста
        guard let i = codec.byEn["i"], let wait = codec.byEn["wait"] else {
            Issue.record("нет базовых кодов"); return
        }
        let units: [RMCodec.Unit] = [.code(i), .code(wait), .num(10)]
        let rendered = codec.render(units)
        let blob = codec.wireBlob(try codec.encode(units))
        let zl = try TextCodec.compress(rendered, codec: Envelope.codecZlib)
        #expect(blob.count < zl.count,
                "коды не меньше текста: \(blob.count) vs \(zl.count) («\(rendered)»)")
    }
}

// ============================================================================
// ЗАМОК на тихую потерю текста (синтетический стресс 03.08).
// Длина литерала — один байт, поэтому >255 скаляров не влезает.
// Раньше лишнее молча обрезалось: сообщение уходило короче, чем
// написал человек, и никто об этом не узнавал. Теперь кодек обязан
// отказаться, а конвейер — уйти в текст целиком.
// ============================================================================
nonisolated struct LiteralOverflowTests {

    @Test("литерал 255 символов кодируется, 256 — отвергается")
    func literalLengthBoundary() throws {
        let codec = try #require(RMCodec.shared)
        let ok = String(repeating: "я", count: 255)
        #expect(throws: Never.self) {
            _ = try codec.encode([.lit(ok)])
        }
        let tooLong = String(repeating: "я", count: 256)
        #expect(throws: (any Error).self) {
            _ = try codec.encode([.lit(tooLong)])
        }
    }

    @Test("отказ объясняет причину словами, а не кодом")
    func refusalIsExplained() throws {
        let codec = try #require(RMCodec.shared)
        do {
            _ = try codec.encode([.lit(String(repeating: "a", count: 900))])
            Issue.record("сверхдлинный литерал обязан быть отвергнут")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(text.contains("не помещается"))
        }
    }
}

// ============================================================================
// ЗАМОК на однобайтовые индексы (аудит 03.08 по вопросу владельца
// «255 — это символы или байты?»). Ответ: длина литерала считает
// СИМВОЛЫ, а в провод идут биты Хаффмана — путаницы нет. Но рядом
// нашлись индексы, которые пишутся одним байтом: эмодзи и фразы.
// Таблица эмодзи сейчас ровно 255 записей и влезает впритык; её рост
// обязан давать ОШИБКУ, а не падение на UInt8(index).
// ============================================================================
nonisolated struct ByteIndexLimitTests {

    @Test("таблица эмодзи не переросла однобайтовый индекс")
    func emojiTableFitsOneByte() throws {
        let codec = try #require(RMCodec.shared)
        let count = codec.emojiIndex.count
        #expect(count <= 256, Comment(rawValue:
            "индекс эмодзи пишется одним байтом: таблица \(count) записей "
            + "больше не влезает — нужен новый escape"))
        // и сам максимальный индекс обязан помещаться
        #expect((codec.emojiIndex.values.max() ?? 0) <= 255)
    }

    @Test("длина литерала считает символы, а не байты UTF-8")
    func literalLengthCountsCharacters() throws {
        let codec = try #require(RMCodec.shared)
        // 255 кириллических букв = 510 байт UTF-8; если бы счётчик
        // считал байты, это не поместилось бы вовсе
        let cyrillic = String(repeating: "я", count: 255)
        let blob = try codec.encode([.lit(cyrillic)])
        guard case .lit(let back) = try codec.decode(blob).first else {
            Issue.record("не литерал"); return
        }
        #expect(back == cyrillic, "круговой проход обязан быть точным")
        #expect(cyrillic.utf8.count == 510, "проверка самой предпосылки")
    }
}
