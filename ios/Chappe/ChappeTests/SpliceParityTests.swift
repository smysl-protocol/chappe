import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Паритет нарезки/склейки диктовки с эталоном
// tools/dictation/dictation_splice.py: Swift обязан сходиться со ВСЕМИ
// векторами dictation_splice_testvectors.json точь-в-точь (11 штук,
// включая фикстуру «последний чанк выжил» — ловит старое поведение).
// ============================================================================

nonisolated struct SpliceParityTests {

    private func vectors() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/dictation/dictation_splice_testvectors.json")
        return try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test("Покрытие: 3 вектора (ratio ±0.005 и флаг частичности)")
    func coverageVectors() throws {
        for v in try vectors()["coverage"] as! [[String: Any]] {
            let segments = (v["segments"] as! [[Double]])
                .map { (start: $0[0], duration: $0[1]) }
            let duration = v["duration"] as! Double
            let ratio = SpeechDictation.coverageRatio(segments: segments,
                                                      duration: duration)
            #expect(abs(ratio - (v["ratio"] as! Double)) < 0.005, "\(v)")
            #expect((ratio < 0.85) == (v["partial"] as! Bool), "\(v)")
        }
    }

    @Test("Точки реза: 3 вектора точь-в-точь (тай-брейк — ближе к цели)")
    func cutVectors() throws {
        for v in try vectors()["cuts"] as! [[String: Any]] {
            let levels = (v["levels"] as! [[Double]])
                .map { (t: $0[0], level: $0[1]) }
            let cuts = SpeechDictation.pickCutPoints(
                levels: levels, duration: v["duration"] as! Double)
            #expect(cuts == v["expected"] as! [Double], "\(v["expected"]!)")
        }
    }

    @Test("Дедуп стыка: 3 вектора точь-в-точь (нормализация без знаков)")
    func dedupVectors() throws {
        for v in try vectors()["dedup"] as! [[String: String]] {
            let joined = SpeechDictation.dedupJoinPair(v["prev"]!, v["next"]!)
            #expect(joined == v["joined"]!, "prev «\(v["prev"]!)»")
        }
    }

    @Test("Склейка: полный тест-1 не теряет голову; отказ → «A […] C»")
    func spliceVectors() throws {
        let all = try vectors()["splice"] as! [[String: Any]]

        // вектор 1: фикстура «последний чанк выжил» — старое поведение
        let first = all[0]
        let chunks = (first["chunks"] as! [[String: Any]]).map {
            (ok: $0["ok"] as! Bool, text: $0["text"] as! String)
        }
        let full = SpeechDictation.splice(chunks)
        for word in first["must_contain"] as! [String] {
            #expect(full.contains(word), "потеряно «\(word)»")
        }
        let head = first["must_not_lose_head"] as! String
        #expect(full.hasPrefix(head), "голова потеряна: «\(full.prefix(40))…»")
        // итог обязан отличаться от «выжил только последний чанк»
        #expect(full != chunks.last!.text, "старое поведение вернулось")

        // вектор 2: отказ среднего чанка
        let second = all[1]
        let chunks2 = (second["chunks"] as! [[String: Any]]).map {
            (ok: $0["ok"] as! Bool, text: $0["text"] as! String)
        }
        #expect(SpeechDictation.splice(chunks2)
                == second["expected"] as! String)
    }
}
