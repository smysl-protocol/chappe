import Foundation

// ============================================================================
// Модель позиции и её старение (WP3 слоя карты, docs/map_layer.md §3).
//
// Старение — центральное свойство, а не украшение: точка человека без
// времени врёт. Радиус неопределённости и пороги отображения — жёсткие
// детерминированные правила, покрытые тестами (PositionAgingTests).
// ============================================================================

/// Откуда взялась позиция. Codable — хранилище позиций и грантов
/// пишется в JSON по правилам остальных хранилищ (аддитивные миграции).
nonisolated enum PositionSource: Hashable, Sendable, Codable {
    case own                    // GPS этого устройства
    case peer(String)           // принята от контакта (Contact.id — отпечаток)
    case manual                 // введена руками (например, точка сбора)
}

/// Точность, с которой позицию МОЖНО раскрывать. Уровень задаётся грантом
/// (WP4), а не отрисовкой: загрубление происходит при кодировании.
nonisolated enum PositionPrecision: Hashable, Sendable, Codable {
    case exact
    case coarse(geohashLength: Int)   // 6 ≈ 1.2 км, 5 ≈ 4.9 км, 4 ≈ 39 км
}

/// Один фикс позиции. Иммутабельный: новое знание — новый фикс.
nonisolated struct PositionFix: Hashable, Sendable, Codable {
    let lat: Double
    let lon: Double
    let horizontalAccuracy: Double   // метры, из CoreLocation (или ячейка геохеша)
    let timestamp: Date
    let source: PositionSource
    let precision: PositionPrecision
}

// MARK: - Старение

nonisolated enum PositionAging {

    /// Пешеходная скорость роста неопределённости, м/с (docs/map_layer.md §3).
    static let driftSpeed = GeoMath.walkingSpeed
    /// Потолок радиуса: дальше круг перестаёт нести информацию.
    static let radiusCap = 5_000.0

    /// Категории отображения по возрасту фикса.
    enum Bucket: Equatable, Sendable {
        case fresh        // < 5 минут: плотная точка
        case aging        // < 1 часа: точка с растущим кругом
        case stale        // < 6 часов: приглушённая
        case archived     // старше: архивный вид / скрытие по настройке
    }

    static let freshLimit = 5.0 * 60
    static let agingLimit = 60.0 * 60
    static let staleLimit = 6.0 * 60 * 60

    /// Радиус неопределённости, метры: r(t) = accuracy + 1.4 м/с × Δt, cap 5 км.
    /// Отрицательный возраст (рассинхрон часов) считается нулевым.
    static func uncertaintyRadius(accuracy: Double, ageSeconds: Double) -> Double {
        let age = max(0, ageSeconds)
        return min(radiusCap, max(0, accuracy) + driftSpeed * age)
    }

    static func bucket(ageSeconds: Double) -> Bucket {
        let age = max(0, ageSeconds)
        if age < freshLimit { return .fresh }
        if age < agingLimit { return .aging }
        if age < staleLimit { return .stale }
        return .archived
    }

    /// Подпись возраста для метки — обязательна на каждой метке, не в попапе.
    /// Детерминированные пороги, чтобы тесты не зависели от локали формата.
    /// По-русски (Ф5.3): «just now» на метке «Я» была английской
    /// строкой в русском интерфейсе.
    static func ageLabel(ageSeconds: Double) -> String {
        let age = max(0, ageSeconds)
        if age < 60 { return "только что" }
        if age < 3600 { return "\(Int(age / 60)) мин назад" }
        if age < 86_400 { return "\(Int(age / 3600)) ч назад" }
        return "\(Int(age / 86_400)) дн назад"
    }
}

// MARK: - Удобства

nonisolated extension PositionFix {
    func ageSeconds(now: Date) -> Double {
        now.timeIntervalSince(timestamp)
    }

    func uncertaintyRadius(now: Date) -> Double {
        PositionAging.uncertaintyRadius(accuracy: horizontalAccuracy,
                                        ageSeconds: ageSeconds(now: now))
    }

    func bucket(now: Date) -> PositionAging.Bucket {
        PositionAging.bucket(ageSeconds: ageSeconds(now: now))
    }
}
