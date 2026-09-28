import Foundation
import SwiftUI

// ============================================================================
// Чистая часть рендера меток (WP5): что показывать — решают правила
// старения WP3, здесь только их перевод в цвета/размеры/полигоны.
// Всё детерминировано и покрыто тестами (MarkerRenderingTests).
// ============================================================================

/// Метка на карте. SOS — отдельный вид, всегда доминирует.
nonisolated struct MapMarker: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case own
        case peer(contactID: String, name: String)
        case sos
    }

    let id: String
    let kind: Kind
    let fix: PositionFix

    var title: String {
        switch kind {
        case .own: "Я"
        case .peer(_, let name): name
        case .sos: "SOS"
        }
    }
}

nonisolated enum MarkerRendering {

    /// Цвет точки по возрасту (палитра RMDesign, тёмная тема).
    /// SOS всегда danger, свой — акцент, peer тускнеет с возрастом.
    static func dotColor(for marker: MapMarker, now: Date) -> Color {
        switch marker.kind {
        case .sos: return RMDesign.danger
        case .own: return RMDesign.accent
        case .peer:
            switch marker.fix.bucket(now: now) {
            case .fresh: return RMDesign.success
            case .aging: return RMDesign.warning
            case .stale: return RMDesign.textTertiary
            case .archived: return RMDesign.textTertiary.opacity(0.5)
            }
        }
    }

    /// Прозрачность метки: архивные — полупризрачные.
    static func opacity(for marker: MapMarker, now: Date) -> Double {
        switch marker.fix.bucket(now: now) {
        case .fresh, .aging: 1.0
        case .stale: 0.6
        case .archived: 0.35
        }
    }

    /// Показывать ли метку вообще (архивные скрываются по настройке —
    /// сама настройка в v1 всегда «показывать архивные»).
    static func isVisible(_ marker: MapMarker, now: Date,
                          showArchived: Bool = true) -> Bool {
        if case .sos = marker.kind { return true }   // SOS не скрывается
        if marker.fix.bucket(now: now) == .archived { return showArchived }
        return true
    }

    /// Подпись возраста — ОБЯЗАТЕЛЬНА на каждой метке (не в попапе).
    static func ageLabel(for marker: MapMarker, now: Date) -> String {
        PositionAging.ageLabel(ageSeconds: marker.fix.ageSeconds(now: now))
    }

    /// Координаты полигона круга неопределённости (n-угольник по сфере).
    /// Возвращает пустой массив, если круг рисовать не надо (свежая
    /// собственная точка с точным GPS меньше порога отображения).
    static func uncertaintyCircle(for marker: MapMarker, now: Date,
                                  segments: Int = 64,
                                  minVisibleRadius: Double = 30)
        -> [(lat: Double, lon: Double)] {
        let radius = marker.fix.uncertaintyRadius(now: now)
        guard radius >= minVisibleRadius else { return [] }
        return (0..<segments).map {
            GeoMath.destination(lat: marker.fix.lat, lon: marker.fix.lon,
                                bearingDegrees: Double($0) * 360 / Double(segments),
                                distanceMeters: radius)
        }
    }
}
