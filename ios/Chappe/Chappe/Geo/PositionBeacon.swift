import Foundation

// ============================================================================
// Бюджет эфира для позиционных маячков (WP7, docs/map_layer.md §6).
//
// Маячки — второй по объёму источник трафика после сообщений. Правила:
//   - не больше MapConfig.maxBeaconsPerHourPerContact на контакт (дефолт 6);
//   - при утилизации канала выше порога маячки подавляются целиком,
//     как погодные слои: интерактив важнее фона;
//   - маячок уходит ТОЛЬКО через дверь LocationDisclosurePolicy — бюджет
//     дополняет грант, а не заменяет его.
//
// Событие для маячка — отправка сообщения контакту (WP3: событийная
// модель, никакого таймера). Честное ограничение: реального источника
// утилизации канала до подключения Meshtastic BLE нет — по умолчанию
// utilization = 0 (не подавляется), см. REPORT_map_night.md.
// ============================================================================

/// Чистая арифметика бюджета — тестируется без часов и синглтонов.
nonisolated enum BeaconBudget {

    /// Разрешён ли маячок сейчас, если отправки этому контакту были в
    /// моменты `sentTimes`.
    static func allows(sentTimes: [Date], now: Date,
                       maxPerHour: Int,
                       channelUtilization: Double,
                       suppressionThreshold: Double) -> Bool {
        guard channelUtilization < suppressionThreshold else { return false }
        let hourAgo = now.addingTimeInterval(-3600)
        let recent = sentTimes.filter { $0 > hourAgo && $0 <= now }
        return recent.count < maxPerHour
    }
}

/// Отправка маячка после события «сообщение ушло контакту».
@MainActor
final class PositionBeacon {

    static let shared = PositionBeacon()

    /// Журнал отправок по контактам (скользящее окно в час).
    /// Осознанно не персистится: после перезапуска бюджет чистый —
    /// перезапуск не чаще маячков.
    private var sentLog: [String: [Date]] = [:]

    /// Источник утилизации канала; до Meshtastic BLE реального нет.
    var channelUtilization: () -> Double = { 0 }

    /// Вызывается после успешной отправки сообщения контакту.
    /// Молча не делает ничего, если: нет гранта (дверь закрыта), бюджет
    /// исчерпан, канал занят или нет своего фикса. Свежий GPS НЕ
    /// запрашивается — используется последний фикс (событийная модель).
    @discardableResult
    func afterMessageSent(to contactID: String, now: Date = Date()) -> Bool {
        guard let fix = LocationProvider.shared.lastFix else { return false }
        guard BeaconBudget.allows(
            sentTimes: sentLog[contactID] ?? [], now: now,
            maxPerHour: MapConfig.maxBeaconsPerHourPerContact,
            channelUtilization: channelUtilization(),
            suppressionThreshold: MapConfig.beaconSuppressionUtilization)
        else { return false }

        // Единственная дверь: без активного гранта disclose бросает,
        // и маячок просто не рождается. Дальше — только шов
        // LocationTransport (п.5): очередь и доставка за ним.
        guard let disclosed = try? LocationDisclosurePolicy.disclose(
            fix, to: contactID, now: now) else { return false }
        guard LocationTransport.shared.send(disclosed) else { return false }

        sentLog[contactID, default: []].append(now)
        // подрезаем окно, чтобы журнал не рос бесконечно
        let hourAgo = now.addingTimeInterval(-3600)
        sentLog[contactID] = sentLog[contactID]?.filter { $0 > hourAgo }
        return true
    }
}
