import Foundation
import Testing
@testable import Chappe

// ============================================================================
// «Взгляд англичанина»: разворот кодов en-строками (Dev-тумблер RU/EN).
// Байты не меняются — только показ.
// ============================================================================

nonisolated struct ENUnfoldTests {

    @Test("EN-разворот: человечные протекты, без подчёркиваний")
    func enRenderHumanizesProtectedCodes() throws {
        let codec = try #require(RMCodec.shared)
        let units: [RMCodec.Unit] = [
            .code(try #require(codec.byEn["sos_active"])),
            .code(try #require(codec.byEn["need_bandages"])),
            .num(3),
            .name("Mark"),
        ]
        let en = codec.render(units, lang: "en")
        #expect(en.contains("SOS ALERT"), "\(en)")
        #expect(en.contains("need bandages"))
        #expect(!en.contains("_"), "подчёркивания наружу нельзя: \(en)")
        #expect(en.contains("3") && en.contains("Mark"))

        // RU-разворот тем же юнитам не сломан
        let ru = codec.render(units, lang: "ru")
        #expect(ru.contains("СИГНАЛ БЕДСТВИЯ"), "\(ru)")
    }

    @Test("RU_DROP-аналога в EN нет: служебные коды видны словами")
    func enKeepsRuDropCodes() throws {
        let codec = try #require(RMCodec.shared)
        // найдём код, который RU глотает, и убедимся: EN его показывает
        guard let dropped = RMCodec.ruDrop.first(where: { codec.byEn[$0] != nil }),
              let code = codec.byEn[dropped] else { return }
        let en = codec.render([.code(code), .num(5)], lang: "en")
        let expected = dropped.replacingOccurrences(of: "_", with: " ")
        #expect(en.lowercased().contains(expected.lowercased()),
                "EN обязан показать «\(expected)»: \(en)")
    }
}
