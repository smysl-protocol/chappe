import Foundation
import Combine
import CoreBluetooth

// ============================================================================
// Обзорный скан радиоустройств (просьба владельца 10.08): пока дальняя
// связь ДЕРЖИТ узел, экран всё равно показывает другие устройства
// рядом и даёт сменить узел.
//
// Ключевое отличие от NodeProbe: этот сканер НИКОГДА не подключается —
// только реклама (имя + RSSI). Скан не мешает живому соединению
// MeshtasticLink (запрет 02.08 касался ПОДКЛЮЧЕНИЯ проверки к узлу,
// которым распоряжается транспорт, — не пассивного наблюдения эфира).
// ============================================================================

@MainActor
final class RadioOverviewScanner: NSObject, ObservableObject {

    struct Seen: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        let lastSeen: Date
    }

    @Published private(set) var seen: [Seen] = []
    @Published private(set) var scanning = false

    /// Реклама старше этого — устройство ушло из эфира (выключено или
    /// ПОДКЛЮЧИЛОСЬ: подключённая периферия не рекламируется). Полевой
    /// скрин 10.08: узел, ставший текущим, вечно висел в «других».
    static let staleAfter: TimeInterval = 10

    private var central: CBCentralManager?
    private var sweepTimer: Timer?

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 5,
                                          repeats: true) { _ in
            Task { @MainActor [weak self] in self?.sweepStale() }
        }
    }

    private func sweepStale() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        seen.removeAll { $0.lastSeen < cutoff }
    }

    func stop() {
        central?.stopScan()
        central = nil
        sweepTimer?.invalidate()
        sweepTimer = nil
        scanning = false
        seen = []
    }
}

extension RadioOverviewScanner: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central.state == .poweredOn else {
                scanning = false
                return
            }
            // Дубликаты ВКЛЮЧЕНЫ намеренно (полевой скрин 10.08 18:38,
            // «другие: 0» при живом узле): с false CoreBluetooth
            // сообщает об устройстве один раз за сессию скана — запись
            // протухала через 10 с и больше не возвращалась НИКОГДА.
            // С дубликатами реклама сыпется постоянно, lastSeen живёт,
            // а ушедшие (выключенные или ПОДКЛЮЧЁННЫЕ другим телефоном
            // — подключённая периферия не рекламируется) честно
            // пропадают. Цена — лишние колбэки на диагностическом
            // экране, открытом минуты.
            central.scanForPeripherals(
                withServices: [MeshtasticLink.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scanning = true
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "устройство"
        let entry = Seen(id: peripheral.identifier, name: name,
                         rssi: RSSI.intValue, lastSeen: Date())
        MainActor.assumeIsolated {
            if let index = seen.firstIndex(where: { $0.id == entry.id }) {
                seen[index] = entry
            } else {
                seen.append(entry)
            }
        }
    }
}
