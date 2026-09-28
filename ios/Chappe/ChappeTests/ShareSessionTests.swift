//
//  ShareSessionTests.swift
//  RMTests
//
//  Жизненный цикл фоновой сессии == жизненный цикл гранта (п.3 плана
//  29.07): включается только выдачей гранта, гаснет по отзыву и
//  истечению, перезапуск приложения её НЕ восстанавливает — состояние
//  «грант активен, обновления не идут» обязано быть представимо.
//

import Foundation
import Testing
@testable import Chappe

private let t0 = Date(timeIntervalSince1970: 1_753_950_000)

/// Фальшивая фоновая сессия: в юнит-тестах настоящую
/// CLBackgroundActivitySession не создать (нужна UI-сцена).
private final class FakeHandle: BackgroundActivityHandle {
    var invalidated = false
    func invalidate() { invalidated = true }
}

@MainActor
struct ShareSessionTests {

    private func makeController(storage: MemoryGrantStorage)
        -> (ShareSessionController, () -> FakeHandle?) {
        var last: FakeHandle?
        let controller = ShareSessionController(
            makeSession: { let h = FakeHandle(); last = h; return h },
            grantStorage: storage)
        return (controller, { last })
    }

    @Test func issuingGrantStartsBackgroundUpdates() {
        let storage = MemoryGrantStorage()
        let (controller, _) = makeController(storage: storage)
        LocationDisclosurePolicy.grant(to: "c1", precision: .exact,
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        controller.grantIssued(now: t0)
        #expect(controller.backgroundUpdatesActive)
    }

    @Test func withoutGrantNothingStarts() {
        // Вне активного гранта фоновые обновления не включаются никогда
        let storage = MemoryGrantStorage()
        let (controller, handle) = makeController(storage: storage)
        controller.grantIssued(now: t0)
        #expect(!controller.backgroundUpdatesActive)
        #expect(handle() == nil)
    }

    @Test func revokeInvalidatesSession() {
        let storage = MemoryGrantStorage()
        let (controller, handle) = makeController(storage: storage)
        LocationDisclosurePolicy.grant(to: "c1", precision: .exact,
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        controller.grantIssued(now: t0)
        LocationDisclosurePolicy.revoke(contactID: "c1", storage: storage)
        controller.syncWithGrants(now: t0.addingTimeInterval(60))
        #expect(!controller.backgroundUpdatesActive)
        #expect(handle()?.invalidated == true)
    }

    @Test func expiryEndsSession() {
        let storage = MemoryGrantStorage()
        let (controller, handle) = makeController(storage: storage)
        LocationDisclosurePolicy.grant(to: "c1", precision: .exact,
                                       ttlSeconds: 100, now: t0,
                                       storage: storage)
        controller.grantIssued(now: t0)
        // время прошло — грант истёк, сессия обязана погаснуть
        controller.syncWithGrants(now: t0.addingTimeInterval(101))
        #expect(!controller.backgroundUpdatesActive)
        #expect(handle()?.invalidated == true)
    }

    @Test func freshProcessIsOffUntilResumed() {
        // До вызова resumeOnAppOpen (например, посреди запуска) свежий
        // контроллер при живом гранте ничего не включает сам по себе
        let storage = MemoryGrantStorage()
        LocationDisclosurePolicy.grant(to: "c1", precision: .exact,
                                       ttlSeconds: 4 * 3600, now: t0,
                                       storage: storage)
        let (controller, _) = makeController(storage: storage)
        controller.syncWithGrants(now: t0.addingTimeInterval(60))
        #expect(!controller.backgroundUpdatesActive)
    }

    @Test func manualAppOpenResumesLiveGrant() {
        // Решение 29.07: грант жив по таймеру + пользователь открыл
        // приложение вручную → сессия возобновляется автоматически,
        // с явным состоянием «возобновлены» (не «свежая выдача»)
        let storage = MemoryGrantStorage()
        LocationDisclosurePolicy.grant(to: "c1", precision: .exact,
                                       ttlSeconds: 4 * 3600, now: t0,
                                       storage: storage)
        let (controller, _) = makeController(storage: storage)
        controller.resumeOnAppOpen(now: t0.addingTimeInterval(3600))
        #expect(controller.backgroundUpdatesActive)
        #expect(controller.resumedAutomatically)
        // свежая выдача сбрасывает флаг «возобновлено»
        controller.grantIssued(now: t0.addingTimeInterval(3700))
        #expect(!controller.resumedAutomatically)
    }

    @Test func appOpenWithoutLiveGrantResumesNothing() {
        // Вне активного гранта — никогда: истёкший грант не возобновляется
        let storage = MemoryGrantStorage()
        LocationDisclosurePolicy.grant(to: "c1", precision: .exact,
                                       ttlSeconds: 100, now: t0,
                                       storage: storage)
        let (controller, handle) = makeController(storage: storage)
        controller.resumeOnAppOpen(now: t0.addingTimeInterval(101))
        #expect(!controller.backgroundUpdatesActive)
        #expect(handle() == nil)
    }

    @Test func secondGrantReusesSession() {
        let storage = MemoryGrantStorage()
        let (controller, _) = makeController(storage: storage)
        LocationDisclosurePolicy.grant(to: "c1", precision: .exact,
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        controller.grantIssued(now: t0)
        LocationDisclosurePolicy.grant(to: "c2", precision: .exact,
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        controller.grantIssued(now: t0)
        #expect(controller.backgroundUpdatesActive)
    }
}
