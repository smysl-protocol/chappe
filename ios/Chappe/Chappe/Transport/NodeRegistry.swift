import Foundation

// ============================================================================
// NodeRegistry — реестр известных узлов (WP0, 02.08).
//
// Повод: узел показал EU_868 при регионе проекта SG_923. Узлы с разными
// регионами друг друга НЕ СЛЫШАТ, и это неотличимо от бага отправки —
// поэтому расхождение проверяется кодом и показывается явным
// предупреждением, а не молчанием.
//
// Реестр запоминает регион и имя каждого узла, который мы хоть раз
// прочитали (по идентификатору периферии), и сравнивает:
//   1) регион текущего узла с ожидаемым регионом проекта;
//   2) регионы известных узлов между собой.
// ============================================================================

nonisolated enum NodeRegistry {

    struct Known: Codable, Equatable {
        var name: String?
        var region: String?
        var lastSeen: Date
        /// Размер NodeDB узла при последнем чтении (для карточки WP3).
        var nodeCount: Int?
    }

    /// Регион проекта (CLAUDE.md: SG_923 — Вьетнам и Бали).
    /// Переопределяется в UserDefaults, если владелец сменит план.
    static let expectedDefault = "SG_923"

    static let knownKey = "node.knownNodes"
    static let expectedKey = "node.expectedRegion"

    static func expectedRegion(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: expectedKey) ?? expectedDefault
    }

    /// Смена плана владельцем (экран смены региона): выбранный регион
    /// становится ожидаемым — предупреждения дальше сверяются с ним.
    static func setExpectedRegion(_ region: String,
                                  defaults: UserDefaults = .standard) {
        defaults.set(region, forKey: expectedKey)
    }

    // MARK: Хранение

    static func load(_ defaults: UserDefaults = .standard) -> [String: Known] {
        guard let data = defaults.data(forKey: knownKey),
              let known = try? JSONDecoder().decode([String: Known].self,
                                                    from: data) else {
            return [:]
        }
        return known
    }

    static func record(id: UUID, name: String?, region: String?,
                       nodeCount: Int? = nil,
                       defaults: UserDefaults = .standard) {
        var known = load(defaults)
        known[id.uuidString] = Known(name: name, region: region,
                                     lastSeen: Date(), nodeCount: nodeCount)
        if let data = try? JSONEncoder().encode(known) {
            defaults.set(data, forKey: knownKey)
        }
    }

    static func others(than id: UUID?,
                       defaults: UserDefaults = .standard) -> [Known] {
        load(defaults)
            .filter { $0.key != id?.uuidString }
            .map(\.value)
    }

    // MARK: Предупреждения — чистая логика, покрыта тестами

    /// Пин протокола Meshtastic (аудит зависимостей 05.08): версия
    /// прошивки узлов, с которой сверен наш мини-протобаф (поля
    /// MeshPacket/Data, GATT UUID, fixed32 для to/id — MeshWireTypeTests)
    /// и живой радиообмен (radio_test_2026-08-02). Протокол у Meshtastic
    /// меняется без нашего ведома — узел с ДРУГОЙ мажор.минор прошивкой
    /// обязан порождать предупреждение, а не молчаливую надежду на
    /// совместимость: смена формата снаружи не должна ломать нас молча.
    static let firmwarePin = "2.7.15"

    /// Мажор.минор из строки прошивки («2.7.15.567b8ea» → «2.7»).
    static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Предупреждение о непроверенной прошивке узла; nil — прошивка
    /// в пределах проверенной линии или ещё не прочитана.
    static func firmwareWarning(firmware: String?) -> String? {
        guard let firmware, !firmware.isEmpty else { return nil }
        guard majorMinor(firmware) != majorMinor(firmwarePin) else {
            return nil
        }
        return "Прошивка устройства \(firmware), а протокол проверен с "
            + "\(firmwarePin). Формат обмена мог смениться — прогоните "
            + "радиопроверку, прежде чем полагаться на это устройство."
    }

    /// Список предупреждений для узла с регионом `region`.
    /// Пустой список = всё совпадает или регион ещё не прочитан.
    static func warnings(region: String?, expected: String,
                         others: [Known]) -> [String] {
        guard let region else { return [] }
        var result: [String] = []
        if region != expected {
            result.append("Страна и частоты устройства — \(region), а в "
                + "приложении выбрано \(expected). Устройства с разными "
                + "настройками друг друга не слышат: связи не будет, "
                + "пока настройки не совпадут.")
        }
        for other in others where other.region != nil
            && other.region != region {
            let name = other.name ?? "без имени"
            result.append("У устройства «\(name)» частоты \(other.region!), "
                + "у этого — \(region). Между собой они связаться "
                + "не смогут.")
        }
        return result
    }
}
