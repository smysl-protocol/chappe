import Foundation
import Combine

// ============================================================================
// Позиции собеседников — ЕДИНСТВЕННЫЙ источник правды для карты и Софи.
//
// Хранится ровно один (последний) фикс на контакт. Источник — входящие
// LOCATION-пакеты (DeliveryManager). Второго хранилища позиций в проекте
// быть не должно (docs/map_layer.md §3).
//
// Wire-формат LOCATION не несёт ни точности, ни времени измерения:
// точность берётся консервативной константой, возраст считается от
// момента приёма. Это честно отражается в подписи возраста на карте.
// ============================================================================

@MainActor
final class PeerPositionStore: ObservableObject {

    static let shared = PeerPositionStore()

    /// Точность, приписываемая принятой позиции: эфир её не передаёт.
    /// 50 м — консервативная оценка бытового GPS-фикса.
    nonisolated static let wireDefaultAccuracy = 50.0

    @Published private(set) var positions: [String: PositionFix] = [:]

    /// Инициализация с загрузкой с диска; для тестов — пустой in-memory.
    init(persisted: Bool = true) {
        self.persisted = persisted
        if persisted { positions = Self.loadFromDisk() }
    }

    private let persisted: Bool

    /// Единая точка приёма позиции собеседника.
    /// Возвращает false, если координаты не прошли валидацию диапазонов.
    @discardableResult
    func ingest(contactID: String, lat: Double, lon: Double,
                receivedAt: Date) -> Bool {
        guard (try? Envelope.checkCoords(lat: lat, lon: lon)) != nil else {
            return false
        }
        positions[contactID] = PositionFix(
            lat: lat, lon: lon,
            horizontalAccuracy: Self.wireDefaultAccuracy,
            timestamp: receivedAt,
            source: .peer(contactID),
            precision: .exact)   // фактическую грубость отправителя эфир не сообщает
        if persisted { Self.saveToDisk(positions) }
        return true
    }

    func position(for contactID: String) -> PositionFix? {
        positions[contactID]
    }

    func removePosition(for contactID: String) {
        positions[contactID] = nil
        if persisted { Self.saveToDisk(positions) }
    }

    // MARK: Диск (по правилам остальных хранилищ)

    private nonisolated static func url() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("peer_positions.json")
    }

    private nonisolated static func loadFromDisk() -> [String: PositionFix] {
        guard let url = try? url(),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: PositionFix].self,
                                                   from: data) else { return [:] }
        return dict
    }

    private nonisolated static func saveToDisk(_ positions: [String: PositionFix]) {
        guard let url = try? url(),
              let data = try? JSONEncoder().encode(positions) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
