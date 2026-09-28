import Foundation
import Combine
import CoreLocation

// ============================================================================
// Фоновые обновления позиции — строго на время активного гранта (п.3
// дневного плана 29.07, решение зафиксировано в docs/map_layer.md §3).
//
// Механизм — CLBackgroundActivitySession (iOS 17+): по актуальной доке
// Apple это современный путь для When-In-Use приложений получать
// обновления в фоне с видимым индикатором; требует UIBackgroundModes =
// location (ключ добавлен в проект). allowsBackgroundLocationUpdates —
// legacy-путь, не используем.
//
// Жизненный цикл сессии == жизненный цикл гранта:
//   - создаётся в момент выдачи гранта;
//   - гасится при отзыве и при истечении (таймер на ближайший expiresAt);
//   - сессия умирает вместе с процессом, НО (решение разработчика
//     29.07): если грант ещё жив по таймеру и пользователь ОТКРЫЛ
//     приложение вручную — сессия возобновляется автоматически
//     (открытие приложения = действие человека; система сама
//     приложение не поднимает). Состояние «обновления возобновлены»
//     показывается на экране гранта явно.
//   - вне активного гранта фоновые обновления не включаются никогда.
// ============================================================================

/// Прослойка для тестов: реальная CLBackgroundActivitySession не
/// создаётся в юнит-тестах (симулятор без UI-сцены).
protocol BackgroundActivityHandle {
    func invalidate()
}

extension CLBackgroundActivitySession: BackgroundActivityHandle {}

@MainActor
final class ShareSessionController: ObservableObject {

    static let shared = ShareSessionController()

    /// Фоновые обновления реально включены В ЭТОМ процессе.
    @Published private(set) var backgroundUpdatesActive = false

    /// Сессия возобновлена автоматически при открытии приложения
    /// (не свежей выдачей гранта) — для подписи «обновления возобновлены».
    @Published private(set) var resumedAutomatically = false

    private var session: BackgroundActivityHandle?
    private var expiryTimer: Timer?
    private let makeSession: () -> BackgroundActivityHandle
    private let grantStorage: any GrantStorage

    init(makeSession: @escaping () -> BackgroundActivityHandle
            = { CLBackgroundActivitySession() },
         grantStorage: any GrantStorage = DiskGrantStorage()) {
        self.makeSession = makeSession
        self.grantStorage = grantStorage
    }

    /// Вызывается ТОЛЬКО из выдачи гранта (LocationShareMenu).
    func grantIssued(now: Date = Date()) {
        guard !LocationDisclosurePolicy
            .activeGrants(now: now, storage: grantStorage).isEmpty else { return }
        if session == nil {
            session = makeSession()
            backgroundUpdatesActive = true
        }
        resumedAutomatically = false   // свежая выдача, не возобновление
        scheduleExpiryCheck(now: now)
    }

    /// Пользователь открыл приложение вручную при живом гранте —
    /// возобновляем сессию (вызов из RMApp при старте). Без активного
    /// гранта не делает ничего.
    func resumeOnAppOpen(now: Date = Date()) {
        guard session == nil,
              !LocationDisclosurePolicy
                  .activeGrants(now: now, storage: grantStorage).isEmpty
        else { return }
        session = makeSession()
        backgroundUpdatesActive = true
        resumedAutomatically = true
        scheduleExpiryCheck(now: now)
    }

    /// Вызывается при отзыве; также дёргается таймером истечения.
    func syncWithGrants(now: Date = Date()) {
        let active = LocationDisclosurePolicy
            .activeGrants(now: now, storage: grantStorage)
        if active.isEmpty {
            session?.invalidate()
            session = nil
            backgroundUpdatesActive = false
            resumedAutomatically = false
            expiryTimer?.invalidate()
            expiryTimer = nil
        } else {
            scheduleExpiryCheck(now: now)
        }
    }

    /// Таймер на ближайшее истечение (+1 с), чтобы сессия погасла сама,
    /// без открытого экрана.
    private func scheduleExpiryCheck(now: Date) {
        guard session != nil else { return }
        let earliest = LocationDisclosurePolicy
            .activeGrants(now: now, storage: grantStorage)
            .map(\.expiresAt).min()
        guard let earliest else { return }
        expiryTimer?.invalidate()
        let delay = max(1, earliest.timeIntervalSince(now) + 1)
        expiryTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                           repeats: false) { [weak self] _ in
            Task { @MainActor in self?.syncWithGrants() }
        }
    }
}
