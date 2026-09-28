import Foundation
import Testing
@testable import Chappe

// ============================================================================
// WP0 (02.08): расхождение регионов узлов. Реальный случай: узел показал
// EU_868 при регионе проекта SG_923 — с таким расхождением связи не
// будет никогда, и без предупреждения это неотличимо от бага отправки.
// ============================================================================

nonisolated struct NodeRegionTests {

    @Test("регион совпадает с проектом и соседями — тишина")
    func matchIsSilent() {
        let others = [NodeRegistry.Known(name: "T114", region: "SG_923",
                                         lastSeen: .init())]
        #expect(NodeRegistry.warnings(region: "SG_923", expected: "SG_923",
                                      others: others).isEmpty)
    }

    @Test("реальный случай: EU_868 против проектного SG_923")
    func mismatchWithProject() {
        let w = NodeRegistry.warnings(region: "EU_868", expected: "SG_923",
                                      others: [])
        #expect(w.count == 1)
        #expect(w[0].contains("EU_868") && w[0].contains("SG_923"))
        #expect(w[0].contains("не слышат"))
    }

    @Test("два узла в разных регионах — предупреждение про пару")
    func mismatchBetweenNodes() {
        let others = [NodeRegistry.Known(name: "ThinkNode M1",
                                         region: "SG_923",
                                         lastSeen: .init())]
        let w = NodeRegistry.warnings(region: "EU_868", expected: "EU_868",
                                      others: others)
        #expect(w.count == 1)
        #expect(w[0].contains("ThinkNode M1") && w[0].contains("SG_923"))
    }

    @Test("регион ещё не прочитан — не пугаем")
    func unknownRegionIsSilent() {
        #expect(NodeRegistry.warnings(region: nil, expected: "SG_923",
                                      others: []).isEmpty)
    }

    @Test("реестр: запись и выборка чужих узлов")
    func registryRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.nodes"))
        defaults.removePersistentDomain(forName: "test.nodes")
        let a = UUID(), b = UUID()
        NodeRegistry.record(id: a, name: "A", region: "EU_868",
                            defaults: defaults)
        NodeRegistry.record(id: b, name: "B", region: "SG_923",
                            defaults: defaults)
        let others = NodeRegistry.others(than: a, defaults: defaults)
        #expect(others == [NodeRegistry.Known(
            name: "B", region: "SG_923",
            lastSeen: others.first?.lastSeen ?? .init())])
        // повторная запись того же узла не плодит записей
        NodeRegistry.record(id: a, name: "A", region: "EU_868",
                            defaults: defaults)
        #expect(NodeRegistry.load(defaults).count == 2)
        defaults.removePersistentDomain(forName: "test.nodes")
    }
}

// Пин протокола Meshtastic (аудит зависимостей 05.08): узел с чужой
// мажор.минор прошивкой обязан порождать предупреждение — формат у
// Meshtastic меняется без нашего ведома, молчаливая совместимость
// запрещена. «2.7.15.567b8ea» — строка живого узла из
// docs/reports/radio_test_2026-08-02.md (внешнее ожидание).
nonisolated struct FirmwarePinTests {

    @Test("прошивка проверенной линии — без предупреждения")
    func pinnedLineIsQuiet() {
        #expect(NodeRegistry.firmwareWarning(firmware: "2.7.15.567b8ea") == nil)
        #expect(NodeRegistry.firmwareWarning(firmware: "2.7.20") == nil)
    }

    @Test("чужая мажор.минор — предупреждение с обеими версиями")
    func foreignLineWarns() throws {
        let warning = try #require(
            NodeRegistry.firmwareWarning(firmware: "2.8.0.abc123"))
        #expect(warning.contains("2.8.0.abc123"))
        #expect(warning.contains("2.7.15"))
    }

    @Test("прошивка не прочитана — молчание, не ложная тревога")
    func unknownFirmwareIsQuiet() {
        #expect(NodeRegistry.firmwareWarning(firmware: nil) == nil)
        #expect(NodeRegistry.firmwareWarning(firmware: "") == nil)
    }
}
