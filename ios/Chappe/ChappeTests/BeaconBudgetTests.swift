//
//  BeaconBudgetTests.swift
//  RMTests
//
//  Бюджет эфира (WP7): N маячков в час на контакт, подавление при
//  занятом канале. Чистая арифметика — время подкручивается явно.
//

import Foundation
import Testing
@testable import Chappe

private let t0 = Date(timeIntervalSince1970: 1_753_800_000)

struct BeaconBudgetTests {

    @Test func allowsUpToLimitPerHour() {
        var sent: [Date] = []
        var allowed = 0
        // 10 попыток подряд, лимит 6 — пройдут ровно 6
        for minute in 0..<10 {
            let now = t0.addingTimeInterval(Double(minute) * 60)
            if BeaconBudget.allows(sentTimes: sent, now: now, maxPerHour: 6,
                                   channelUtilization: 0,
                                   suppressionThreshold: 0.5) {
                sent.append(now)
                allowed += 1
            }
        }
        #expect(allowed == 6)
    }

    @Test func windowSlidesAfterAnHour() {
        // 6 маячков в первый час — лимит выбран
        let sent = (0..<6).map { t0.addingTimeInterval(Double($0) * 600) }
        #expect(!BeaconBudget.allows(sentTimes: sent,
                                     now: t0.addingTimeInterval(3500),
                                     maxPerHour: 6, channelUtilization: 0,
                                     suppressionThreshold: 0.5))
        // час спустя первые отправки выпали из окна — снова можно
        #expect(BeaconBudget.allows(sentTimes: sent,
                                    now: t0.addingTimeInterval(3700),
                                    maxPerHour: 6, channelUtilization: 0,
                                    suppressionThreshold: 0.5))
    }

    @Test func busyChannelSuppressesEverything() {
        // Канал занят выше порога — маячки подавляются целиком,
        // даже если лимит не выбран
        #expect(!BeaconBudget.allows(sentTimes: [], now: t0, maxPerHour: 6,
                                     channelUtilization: 0.6,
                                     suppressionThreshold: 0.5))
        #expect(BeaconBudget.allows(sentTimes: [], now: t0, maxPerHour: 6,
                                    channelUtilization: 0.4,
                                    suppressionThreshold: 0.5))
    }

    @Test func configHasSaneDefaults() {
        #expect(MapConfig.maxBeaconsPerHourPerContact == 6)
        #expect(MapConfig.beaconSuppressionUtilization == 0.5)
        #expect(MapConfig.minFreeDiskBytes == 500_000_000)
    }
}
