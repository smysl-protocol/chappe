import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Гейт размера текстового пути (красная сессия 05.08, пункт 0).
// До починки: sealed-текст всегда zlib («ок» 2 Б → ~10 Б — треть живого
// трафика это реплики ≤4 слов), широковещательный без контакта — всегда
// store (длинное в эфир без сжатия), семантический гейт сравнивал блоб
// с zlib РЕНДЕРА, хотя при отказе текстом уходит ИСХОДНИК (кейс #5361
// живого корпуса: блоб 42 Б против текста 38 Б).
// Основание: docs/reports/size_gate_audit_2026-08-05.md.
// ============================================================================

// Имя: в LiteralCanonTests уже живёт SizeGateTests (долг 4, формула
// гейта изолированно) — этот набор про ПУТИ отправки, имя другое.
nonisolated struct TextPathSizeGateTests {

    @Test("«ок» — store, байт-в-байт utf-8, никакого zlib-раздувания")
    func shortGoesStore() {
        let (codec, data) = TextCodec.best("ок")
        #expect(codec == Envelope.codecStore)
        #expect(data == Array("ок".utf8))   // 4 Б, не ~10 zlib
    }

    @Test("длинный повторяющийся текст — zlib и строго меньше store")
    func longGoesZlib() {
        let text = String(repeating: "встречаемся у лодочной станции ",
                          count: 12)
        let (codec, data) = TextCodec.best(text)
        #expect(codec == Envelope.codecZlib)
        #expect(data.count < text.utf8.count)
    }

    @Test("выбор никогда не хуже store — внешняя граница")
    func neverWorseThanStore() {
        for text in ["ок", "да", "выехал", "?", "спасибо 🙏",
                     "Привет! Как дела на Бали?",
                     String(repeating: "а", count: 500)] {
            let (_, data) = TextCodec.best(text)
            #expect(data.count <= text.utf8.count,
                    "best(\(text.prefix(10))…) раздул payload")
        }
    }

    @Test("кейс #5361: блоб больше текста-исходника — finish отдаёт текст")
    func finishComparesAgainstSource() throws {
        let codec = try #require(RMCodec.shared)
        // юниты с двумя NAME — блоб заведомо длиннее сжатого текста.
        // 11.08: источник = ДОСЛОВНЫЙ декод блоба — фикстура проходит
        // замок round-trip и проверяет именно размерный гейт (лоссовый
        // источник перехватывал бы замок раньше, другой причиной).
        let end = try #require(codec.byEn["sent_end"])
        let units: [RMCodec.Unit] = [
            .name("Martha"), .name("Fang"), .name("Clinic"), .code(end),
            .name("Martha"), .name("Fang"), .name("Clinic"), .code(end),
        ]
        let blob = try codec.encode(units)
        let source = try TextCodec.decompress(codec.wireBlob(blob),
                                              codec: Envelope.codecSemantic)
        let encoded = SemanticEncoder.Encoded(
            pivotRaw: "p", pivot: "p", units: units, blob: blob,
            rendered: codec.render(units))
        #expect(SemanticEncoder.roundTripGateReason(source: source,
                                                    blob: blob) == nil,
                "предусловие: дословный источник обязан проходить замок")
        #expect(codec.wireBlob(blob).count
                > TextCodec.best(source).data.count,
                "предусловие кейса: блоб обязан быть больше текста")
        let outcome = SemanticEncoder.finish(encoded, source: source)
        guard case .text(let reason, _) = outcome else {
            Issue.record("блоб больше текста, а finish отдал семантику")
            return
        }
        #expect(reason == "текст короче семантики")
    }

    @Test("широковещательный текст: длинное больше не уходит store")
    func broadcastLongCompressed() throws {
        let text = String(repeating: "повторяющийся длинный текст ",
                          count: 10)
        let queued = try Outbox.enqueue(text: text, entryID: UUID())
        // все пакеты вместе обязаны быть меньше сырого utf-8 + обвязка
        #expect(queued.totalBytes < text.utf8.count,
                "длинный широковещательный текст ушёл несжатым")
    }
}
