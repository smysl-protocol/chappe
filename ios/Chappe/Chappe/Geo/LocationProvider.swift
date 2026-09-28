import Foundation
import Combine
import CoreLocation

// ============================================================================
// Событийный источник СВОЕЙ позиции (WP3, docs/map_layer.md §3).
//
// Никакого непрерывного GPS: только one-shot requestLocation по событию —
// явный запрос пользователя (кнопка «моё положение», шеринг), отправка
// сообщения. Паттерн тот же, что у проверенного LocationFetcher Софи
// (When-In-Use + requestLocation + delegate → continuation), но наружу
// отдаётся полный PositionFix: с horizontalAccuracy и timestamp — без них
// правила старения не работают.
//
// Significant-change monitoring в v1 НЕ включён: ему нужна авторизация
// Always и фоновые режимы, которых в проекте нет (см. открытые вопросы
// docs/map_layer.md §7.2) — решение за владельцем.
// ============================================================================

@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = LocationProvider()

    nonisolated enum Outcome: Sendable {
        case fix(PositionFix)
        case denied
        case unavailable(String)
    }

    /// Последний известный свой фикс — источник для карты и для шеринга.
    /// Стареет по общим правилам PositionAging, как и позиции собеседников.
    @Published private(set) var lastFix: PositionFix?

    private let manager = CLLocationManager()
    private var continuations: [CheckedContinuation<Outcome, Never>] = []

    /// Однократный запрос позиции по событию. Параллельные вызовы
    /// склеиваются в один запрос к CoreLocation.
    func requestFix() async -> Outcome {
        manager.delegate = self
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // продолжение — в didChangeAuthorization
        default:
            break
        }
        return await withCheckedContinuation { c in
            continuations.append(c)
            if continuations.count == 1,
               manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        let waiting = continuations
        continuations = []
        for c in waiting { c.resume(returning: outcome) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if !self.continuations.isEmpty { self.manager.requestLocation() }
            case .denied, .restricted:
                self.finish(.denied)
            case .notDetermined:
                break   // ждём решения пользователя
            @unknown default:
                self.finish(.unavailable("неизвестный статус разрешения"))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else {
                self.finish(.unavailable("пустой ответ геосервиса"))
                return
            }
            let fix = PositionFix(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude,
                horizontalAccuracy: max(0, location.horizontalAccuracy),
                timestamp: location.timestamp,
                source: .own,
                precision: .exact)
            self.lastFix = fix
            self.finish(.fix(fix))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(.unavailable(error.localizedDescription))
        }
    }
}
