import Testing
import Foundation
@testable import Chappe

// Правила предложения «познакомить телефоны» (бриф 07.08).
// Ожидания — из брифа, а не из кода: отказ навсегда; фоном не
// предлагаем; ручная кнопка снимает отказ.
@MainActor
struct NearbyPresenceTests {

    private func fresh(_ id: String) -> NearbyPresence {
        let presence = NearbyPresence.shared
        presence.clearDeclined(contactID: id)
        return presence
    }

    @Test func noOfferWhenContactNotNearby() {
        let presence = fresh("TEST0001")
        // пакетов от контакта не было — предложения быть не должно
        #expect(presence.isNearby(contactID: "TEST0001") == false)
        #expect(presence.shouldOfferPairing(contactID: "TEST0001",
                                            alreadyPaired: false) == false)
    }

    @Test func offerWhenNearbyAndNotPaired() {
        let presence = fresh("TEST0002")
        presence.markSeenNearby(contactID: "TEST0002")
        #expect(presence.shouldOfferPairing(contactID: "TEST0002",
                                            alreadyPaired: false) == true)
        // уже знакомы телефонами — предлагать нечего
        #expect(presence.shouldOfferPairing(contactID: "TEST0002",
                                            alreadyPaired: true) == false)
    }

    @Test func declineIsForever() {
        let presence = fresh("TEST0003")
        presence.markSeenNearby(contactID: "TEST0003")
        presence.markDeclined(contactID: "TEST0003")
        #expect(presence.shouldOfferPairing(contactID: "TEST0003",
                                            alreadyPaired: false) == false)
        // и остаётся отказом даже когда он снова рядом
        presence.markSeenNearby(contactID: "TEST0003")
        #expect(presence.shouldOfferPairing(contactID: "TEST0003",
                                            alreadyPaired: false) == false)
        // ручная кнопка — дверь обратно
        presence.clearDeclined(contactID: "TEST0003")
        #expect(presence.shouldOfferPairing(contactID: "TEST0003",
                                            alreadyPaired: false) == true)
    }

    @Test func presenceGoesStale() {
        let presence = fresh("TEST0004")
        presence.markSeenNearby(contactID: "TEST0004")
        let later = Date().addingTimeInterval(NearbyPresence.freshness + 1)
        #expect(presence.isNearby(contactID: "TEST0004", now: later) == false)
    }

    // Исход проверяется фактом, а не молчанием (п.3 брифа).
    @Test func failureLineSaysWhatToDo() {
        #expect(NearbyPairingOutcome.failureLine(pairedAfter: true) == nil)
        let line = NearbyPairingOutcome.failureLine(pairedAfter: false)
        #expect(line?.contains("Не получилось") == true)
        #expect(line?.contains("открыть приложение") == true)
    }
}
