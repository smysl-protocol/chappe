//
//  PositionAgingTests.swift
//  RMTests
//
//  Правила старения позиции (docs/map_layer.md §3): радиус
//  r(t) = accuracy + 1.4 м/с × Δt с потолком 5 км, пороги отображения
//  5 мин / 1 ч / 6 ч, подпись возраста обязательна. Всё детерминировано,
//  время в тестах «подкручивается» явными датами.
//

import Foundation
import Testing
@testable import Chappe

struct PositionAgingTests {

    @Test func radiusGrowsAtWalkingSpeed() {
        // 10 м точности + 100 с × 1.4 м/с = 150 м
        #expect(PositionAging.uncertaintyRadius(accuracy: 10, ageSeconds: 100) == 150)
        // свежий фикс — только точность GPS
        #expect(PositionAging.uncertaintyRadius(accuracy: 25, ageSeconds: 0) == 25)
    }

    @Test func radiusIsCappedAt5km() {
        // Через час: 10 + 3600×1.4 = 5050 → потолок 5000
        #expect(PositionAging.uncertaintyRadius(accuracy: 10, ageSeconds: 3600) == 5000)
        // Сутки — всё ещё 5000, круг не съедает всю карту
        #expect(PositionAging.uncertaintyRadius(accuracy: 10, ageSeconds: 86_400) == 5000)
    }

    @Test func negativeAgeIsTreatedAsZero() {
        // Рассинхрон часов не даёт радиусу «сжаться» ниже точности
        #expect(PositionAging.uncertaintyRadius(accuracy: 30, ageSeconds: -500) == 30)
        #expect(PositionAging.bucket(ageSeconds: -500) == .fresh)
    }

    @Test func displayBuckets() {
        #expect(PositionAging.bucket(ageSeconds: 0) == .fresh)
        #expect(PositionAging.bucket(ageSeconds: 299) == .fresh)
        #expect(PositionAging.bucket(ageSeconds: 300) == .aging)
        #expect(PositionAging.bucket(ageSeconds: 3599) == .aging)
        #expect(PositionAging.bucket(ageSeconds: 3600) == .stale)
        #expect(PositionAging.bucket(ageSeconds: 21_599) == .stale)
        #expect(PositionAging.bucket(ageSeconds: 21_600) == .archived)
    }

    @Test func ageLabelIsAlwaysPresent() {
        #expect(PositionAging.ageLabel(ageSeconds: 10) == "только что")
        #expect(PositionAging.ageLabel(ageSeconds: 40 * 60) == "40 мин назад")
        #expect(PositionAging.ageLabel(ageSeconds: 2 * 3600) == "2 ч назад")
        #expect(PositionAging.ageLabel(ageSeconds: 3 * 86_400) == "3 дн назад")
    }

    @Test func fixConvenienceUsesTimestamp() {
        let t0 = Date(timeIntervalSince1970: 1_753_600_000)
        let fix = PositionFix(lat: 0, lon: 0, horizontalAccuracy: 20,
                              timestamp: t0, source: .own, precision: .exact)
        let now = t0.addingTimeInterval(600)   // 10 минут спустя
        #expect(fix.ageSeconds(now: now) == 600)
        #expect(fix.uncertaintyRadius(now: now) == 20 + 600 * 1.4)
        #expect(fix.bucket(now: now) == .aging)
    }
}
