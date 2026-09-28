import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Знакомство «одним баннером» УБРАНО (вердикт владельца 14.08): полевые
// прогоны нестабильны — чат создавался на одном телефоне из двух,
// задержки до минут; баннеры висели поверх открытого чата. Знакомство —
// ТОЛЬКО через QR (показ/скан). Замок стережёт закрытую дверь: кадры
// старых сборок (магия RMINTR1, формат из спеки — руками) узнаются
// развилкой приёма и НЕ доставляются никуда. Слом: вернуть обработку
// интро в NearbyTransport.route / убрать развилку — красный.
// ============================================================================

nonisolated struct IntroduceRemovedTests {

    @Test("дверь закрыта: интро-кадры отбрасываются, конверты — проходят")
    func introFramesAreDropped() {
        // кадр объявления руками по спеке старого формата
        let json = "{\"v\":1,\"name\":\"Старый Сосед\",\"pub\":\"AA==\"}"
        let offer = Array("RMINTR1".utf8) + [UInt8(0)]
            + Array(Data(json.utf8).base64EncodedString().utf8)
        #expect(NearbyTransport.routeVerdict(offer) == .droppedIntro,
                Comment(rawValue: "фича убрана — кадр старой сборки не "
                + "смеет родить ни баннер, ни контакт"))
        // ответный кадр — тоже мимо
        let reply = Array("RMINTR1".utf8) + [UInt8(1)]
            + Array("ABCDEFGH".utf8) + Array("cGF5bG9hZA==".utf8)
        #expect(NearbyTransport.routeVerdict(reply) == .droppedIntro)
        // обычные байты конверта идут дальше как шли
        #expect(NearbyTransport.routeVerdict([0x02, 0x01, 0x00, 0x7F])
                == .deliver, "не-интро трафик развилка не трогает")
        #expect(NearbyTransport.routeVerdict([]) == .deliver)
    }
}

// ============================================================================
// Замки на Retry-After погоды (заказ владельца 08.08): клиент честен —
// читает просьбу сервиса о паузе и не долбит раньше срока.
// ============================================================================

struct WeatherRetryAfterTests {

    @Test("Retry-After: секунды, HTTP-дата, мусор")
    func retryAfterParsing() {
        #expect(WeatherRemoteSource.retryAfterSeconds("120") == 120)
        #expect(WeatherRemoteSource.retryAfterSeconds(" 0 ") == 0)
        // дата из RFC 9110 (пример спеки), напротив «сейчас» за 30 с до неё
        let now = ISO8601DateFormatter().date(
            from: "1994-11-06T08:49:07Z")!.addingTimeInterval(-30)
        #expect(WeatherRemoteSource.retryAfterSeconds(
            "Sun, 06 Nov 1994 08:49:37 GMT", now: now) == 60)
        // дата в прошлом — ноль, не отрицательное
        #expect(WeatherRemoteSource.retryAfterSeconds(
            "Sun, 06 Nov 1994 08:49:37 GMT",
            now: now.addingTimeInterval(3600)) == 0)
        #expect(WeatherRemoteSource.retryAfterSeconds("soon") == nil)
        #expect(WeatherRemoteSource.retryAfterSeconds(nil) == nil)
    }

    @Test("429 — своя честная строка, не «сервис не ответил»")
    func rateLimitLineIsHonest() {
        let line = WeatherStore.fetchErrorLine(
            for: WeatherRemoteSource.SourceError.rateLimited(retryAfter: 240))
        #expect(line.contains("паузу"), Comment(rawValue:
                "полевой 08.08: бейдж говорил «сервис погоды не ответил», "
                + "хотя сервис ясно попросил паузу"))
        #expect(line.contains("4 мин"), "срок из Retry-After виден человеку")
        let vague = WeatherStore.fetchErrorLine(
            for: WeatherRemoteSource.SourceError.rateLimited(retryAfter: nil))
        #expect(vague.contains("паузу"))
        // действующая пауза: строка со сроком до конца
        #expect(WeatherStore.pauseLine(
            until: Date(timeIntervalSince1970: 1000 + 150),
            now: Date(timeIntervalSince1970: 1000)).contains("3 мин"))
    }
}
