import Foundation
import Testing
@testable import Chappe

// ============================================================================
// WP2 (02.08): BLE — один долгоживущий сервис уровня приложения.
// Баг: экран настроек владел соединением (@StateObject + onDisappear
// stop()) — каждый вход сканировал и сопрягался заново. Bluetooth в
// тестах недоступен; проверяется логика сервиса: тот же объект между
// «заходами на экран», возврат не сбрасывает готовое соединение,
// идентификатор периферии переживает перезапуск.
// ============================================================================

@MainActor
struct NodeServiceTests {

    private func lenField(_ f: Int, _ inner: [UInt8]) -> [UInt8] {
        MiniProto.lenField(f, inner)
    }
    private func varField(_ f: Int, _ v: UInt64) -> [UInt8] {
        MiniProto.key(f, wire: 0) + MiniProto.varint(v)
    }

    /// Синтетический «подключённый» probe: конфиг-поток как в
    /// NodeProbeTests, фаза ready без Bluetooth.
    private func readyProbe() -> NodeProbe {
        let probe = NodeProbe()
        probe.ingest(lenField(3, varField(1, 7)))
        probe.ingest(lenField(4, varField(1, 42)))    // чужой узел в NodeDB
        let user = lenField(2, Array("Node Alpha".utf8))
        probe.ingest(lenField(4, varField(1, 7) + lenField(2, user)))
        probe.ingest(lenField(5, lenField(6, varField(7, 18))))   // SG_923
        probe.ingest(varField(7, 1))                              // complete
        return probe
    }

    @Test("сервис один на приложение: экран наблюдает тот же объект")
    func sharedIsSingleton() {
        #expect(NodeProbe.shared === NodeProbe.shared)
    }

    @Test("возврат на экран не трогает готовое соединение")
    func reenterKeepsConnection() {
        let savedOwner = NodeProbe.radioOwnedByTransport
        NodeProbe.radioOwnedByTransport = { false }
        defer { NodeProbe.radioOwnedByTransport = savedOwner }
        let probe = readyProbe()
        #expect(probe.phase == .ready)
        let factsBefore = probe.facts

        probe.startIfNeeded()   // то, что делает onAppear экрана

        #expect(probe.phase == .ready, "повторный вход не должен сканировать")
        #expect(probe.facts == factsBefore, "факты узла не сбрасываются")
    }

    @Test("идентификатор периферии сохраняется для реконнекта без скана")
    func peripheralIDPersists() {
        let saved = UserDefaults.standard.string(
            forKey: NodeProbe.savedPeripheralKey)
        defer { UserDefaults.standard.set(saved,
                forKey: NodeProbe.savedPeripheralKey) }

        let id = UUID()
        NodeProbe().rememberPeripheral(id)
        #expect(NodeProbe.savedPeripheralID == id,
                "id обязан пережить перезапуск (реконнект без скана)")
    }

    @Test("карточка WP3 видит живое состояние сервиса")
    func statusSnapshotReflectsLiveState() {
        let probe = readyProbe()
        let snap = probe.statusSnapshot()
        #expect(snap.connectedNow == true)
        #expect(snap.nodeName == "Node Alpha")
        #expect(snap.region == "SG_923")
        #expect(snap.knownNodeCount == 2)
    }

    // Регрессия 02.08, поймана на первом радиотесте: probe и транспорт
    // дрались за одну периферию — подключённый узел перестаёт
    // рекламироваться, транспорт не находит его сканом, в эфир не
    // уходит ничего. Владелец радио — транспорт.
    @Test("радио занято транспортом: диагностика не подключается")
    func probeYieldsRadioToTransport() {
        let saved = NodeProbe.radioOwnedByTransport
        defer { NodeProbe.radioOwnedByTransport = saved }
        NodeProbe.radioOwnedByTransport = { true }

        let probe = NodeProbe()
        probe.rememberPeripheral(UUID())
        #expect(!probe.restoreConnection(),
                "при транспорте «радио» probe обязан уступить узел")
        // отдельная фаза .yielded вместо красной ошибки: это НОРМА,
        // а не сбой (замечание владельца 02.08 — экран пугал красным)
        probe.startIfNeeded()
        #expect(probe.phase == .yielded,
                "ожидалась фаза «узел отдан транспорту», а не скан")
        probe.startScan()
        #expect(probe.phase == .yielded,
                "явный поиск тоже обязан уступить транспорту")
        probe.yieldRadio()
        #expect(probe.phase == .yielded)
    }

    @Test("транспорт не «радио» — диагностика работает как прежде")
    func probeWorksWhenTransportIsNotMesh() {
        let saved = NodeProbe.radioOwnedByTransport
        defer { NodeProbe.radioOwnedByTransport = saved }
        NodeProbe.radioOwnedByTransport = { false }
        let savedID = UserDefaults.standard.string(
            forKey: NodeProbe.savedPeripheralKey)
        defer { UserDefaults.standard.set(savedID,
                forKey: NodeProbe.savedPeripheralKey) }

        let probe = NodeProbe()
        probe.rememberPeripheral(UUID())
        #expect(probe.restoreConnection())
        #expect(probe.phase == .reconnecting)
    }

    @Test("восстановление по сохранённому id идёт без скана")
    func restoreUsesSavedIDNotScan() {
        let saved = UserDefaults.standard.string(
            forKey: NodeProbe.savedPeripheralKey)
        let savedOwner = NodeProbe.radioOwnedByTransport
        NodeProbe.radioOwnedByTransport = { false }
        defer {
            UserDefaults.standard.set(saved,
                forKey: NodeProbe.savedPeripheralKey)
            NodeProbe.radioOwnedByTransport = savedOwner
        }

        let probe = NodeProbe()
        probe.rememberPeripheral(UUID())
        #expect(probe.restoreConnection(),
                "с сохранённым id восстановление обязано запускаться")
        #expect(probe.phase == .reconnecting,
                "фаза — ожидание узла, не скан")
        // повторный вход на экран не сбивает идущее восстановление
        probe.startIfNeeded()
        #expect(probe.phase == .reconnecting)
    }
}
