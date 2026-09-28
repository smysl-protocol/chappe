import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Долг 5, этапы 2–3: сегментное спасение — локализация провала гейта.
// Акценты владельца (05.08): в текст уходит только провалившее
// предложение; локализация НЕ ослабляет гейт (красные фикстуры остаются
// красными); выдумка в одном предложении не размывается соседними
// здоровыми. Провод не меняется: вербатим — штатный esc_literal.
// ============================================================================

nonisolated struct MixedRescueTests {

    private var codec: RMCodec { RMCodec.shared! }

    /// Юниты «здорового» предложения из словарных слов + граница.
    private func healthyGroup() throws -> [RMCodec.Unit] {
        let wait = try #require(codec.byEn["wait"])
        let home = try #require(codec.byEn["home"])
        let end = try #require(codec.byEn["sent_end"])
        return [.code(wait), .code(home), .code(end)]
    }

    private func encoded(_ units: [RMCodec.Unit]) throws
    -> SemanticEncoder.Encoded {
        SemanticEncoder.Encoded(pivotRaw: "p", pivot: "p", units: units,
                                blob: (try? codec.encode(units)) ?? [],
                                rendered: codec.render(units))
    }

    @Test("выдумка в одном предложении: оно вербатимом, соседи кодами")
    func fabricationIsLocalized() throws {
        // источник: два предложения, во втором нет никакого «сына»
        let source = "Жди дома. Я приду вечером."
        let end = try #require(codec.byEn["sent_end"])
        let son = try #require(codec.byEn["son"])   // выдуманная сущность
        let come = try #require(codec.byEn["come"])
        // «сын» не первым словом: в начале предложения рендер даёт
        // заглавную букву, а капитализированное гейт сущностей считает
        // именем и не гейтит (осознанное свойство гейта)
        let units = try healthyGroup()
            + [.code(come), .code(son), .code(end)]  // «сын» выдуман моделью
        let mixed = try #require(SemanticEncoder.mixedRescue(
            source: source, encoded: encoded(units), codec: codec))

        // провалившее предложение — вербатим-оригиналом
        #expect(mixed.units.contains(.lit("Я приду вечером.")))
        // здоровое — кодами, не литералом
        #expect(mixed.units.contains(.code(try #require(codec.byEn["wait"]))))
        // выдумки в результате нет ни в юнитах, ни в рендере
        #expect(!mixed.units.contains(.code(son)))
        #expect(!mixed.rendered.lowercased().contains("сын"))
    }

    @Test("одно предложение — спасать нечего, уходит текстом как раньше")
    func singleSentenceNotRescued() throws {
        let son = try #require(codec.byEn["son"])
        let units: [RMCodec.Unit] = [.code(son)]
        #expect(SemanticEncoder.mixedRescue(
            source: "жди дома вечером у пирса",
            encoded: try encoded(units), codec: codec) == nil)
    }

    @Test("все предложения провалены — nil, честный текст целиком")
    func allFailedNotRescued() throws {
        let source = "Первое предложение. Второе предложение."
        let son = try #require(codec.byEn["son"])
        let end = try #require(codec.byEn["sent_end"])
        let units: [RMCodec.Unit] = [.code(son), .code(end),
                                     .code(son), .code(end)]
        #expect(SemanticEncoder.mixedRescue(
            source: source, encoded: try encoded(units),
            codec: codec) == nil)
    }

    @Test("несовпадение числа предложений — nil, никаких догадок")
    func misalignmentNotRescued() throws {
        // три предложения источника против двух групп юнитов
        let source = "Раз. Два. Три."
        let son = try #require(codec.byEn["son"])
        let end = try #require(codec.byEn["sent_end"])
        let units = try healthyGroup() + [.code(son), .code(end)]
        #expect(SemanticEncoder.mixedRescue(
            source: source, encoded: try encoded(units),
            codec: codec) == nil)
    }

    @Test("разбиение юнитов по границам предложений")
    func unitGroupSplit() throws {
        let end = try #require(codec.byEn["sent_end"])
        let wait = try #require(codec.byEn["wait"])
        let groups = SemanticEncoder.splitUnitGroups(
            [.code(wait), .code(end), .code(wait), .code(wait), .code(end)],
            codec: codec)
        #expect(groups.count == 2)
        #expect(groups[0].count == 2)
        #expect(groups[1].count == 3)
    }

    @Test("разбиение источника на предложения")
    func sentenceSplit() {
        #expect(SemanticEncoder.splitSentences("Раз. Два! Три?")
                == ["Раз.", "Два!", "Три?"])
        #expect(SemanticEncoder.splitSentences("без пунктуации совсем")
                == ["без пунктуации совсем"])
    }

    @Test("round-trip: смешанный блоб декодируется байт-в-байт")
    func mixedBlobRoundTrip() throws {
        let end = try #require(codec.byEn["sent_end"])
        let wait = try #require(codec.byEn["wait"])
        let units: [RMCodec.Unit] = [.code(wait), .code(end),
                                     .lit("Я приду вечером."), .code(end)]
        let blob = try codec.encode(units)
        let blob2 = try codec.encode(units)
        #expect(blob == blob2, "детерминизм: одни юниты — одни байты")
        let wire = codec.wireBlob(blob)
        let back = try #require(codec.unwrapWire(wire))
        let decoded = try codec.decode(back)
        #expect(try codec.encode(decoded) == blob,
                "round-trip: decode → encode обязан вернуть те же байты")
    }

    @Test("диктовка без пунктуации делится паузами STT")
    func pauseSegmentsRescueUnpunctuated() throws {
        let source = "жди дома приду вечером"
        let son = try #require(codec.byEn["son"])
        let come = try #require(codec.byEn["come"])
        let end = try #require(codec.byEn["sent_end"])
        let units = try healthyGroup() + [.code(come), .code(son), .code(end)]
        // без сегментов — спасать нечего (замер 05.08: 17/17 так отбиты)
        #expect(SemanticEncoder.mixedRescue(
            source: source, encoded: try encoded(units),
            codec: codec) == nil)
        // паузы STT дают сегментацию — провал локализуется
        let mixed = try #require(SemanticEncoder.mixedRescue(
            source: source, encoded: try encoded(units), codec: codec,
            pauseSegments: ["жди дома", "приду вечером"]))
        #expect(mixed.units.contains(.lit("приду вечером")))
        #expect(!mixed.units.contains(.code(son)))
    }

    @Test("вклады чанков склеиваются в тот же текст, что splice")
    func spliceSegmentsParity() {
        let parts: [(ok: Bool, text: String)] = [
            (true, "жди меня у пирса"), (true, "у пирса да у того же"),
            (false, ""), (true, "где вчера")]
        let joined = SpeechDictation.splice(parts)
        let segs = SpeechDictation.spliceSegments(parts)
        #expect(segs.joined(separator: " ") == joined,
                "конкатенация вкладов обязана дать склейку")
        #expect(segs.count >= 2)
    }
}
