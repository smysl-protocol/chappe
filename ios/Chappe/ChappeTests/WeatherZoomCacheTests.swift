import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Кэш паков по шагу сетки (полевое замечание владельца 19.08: зум
// перекачивал погоду заново — «ветер менялся при масштабировании» и
// горела минутная квота сервиса).
//
// Ожидания посчитаны руками, не выведены из кода:
// вьюпорт 24.9…25.3 / 54.9…55.5; зазор 10% размаха = 0.04 широты и
// 0.06 долготы → кэшированный пак обязан покрывать 24.86…25.34 /
// 54.84…55.56. Каждый замок ломает свою проверку: свежесть, покрытие,
// шаг.
// ============================================================================

nonisolated struct WeatherZoomCacheTests {

    private let now = Date(timeIntervalSince1970: 1_755_600_000) // руками

    private let viewport = RegionBBox(minLat: 24.9, minLon: 54.9,
                                      maxLat: 25.3, maxLon: 55.5)

    /// Пак с полями-заглушками: селектор кэша смотрит только на bbox,
    /// шаг и свежесть — значения полей ему безразличны.
    private func pack(latMin: Double, lonMin: Double,
                      latMax: Double, lonMax: Double,
                      step: Double, fetchedSecondsAgo: Double) -> WeatherPack {
        WeatherPack(model: "icon-13km",
                    runDate: now.addingTimeInterval(-4 * 3600),
                    fetchedDate: now.addingTimeInterval(-fetchedSecondsAgo),
                    latMin: latMin, lonMin: lonMin,
                    latMax: latMax, lonMax: lonMax,
                    stepDeg: step, hours: [0, 3], fields: [:])
    }

    @Test func freshCoveringFinePackIsReused() {
        let fine = pack(latMin: 24.0, lonMin: 54.0, latMax: 26.0,
                        lonMax: 57.0, step: 0.25, fetchedSecondsAgo: 300)
        let got = WeatherStore.reusablePack(from: [fine], viewport: viewport,
                                            desiredStep: 0.25, now: now)
        #expect(got == fine, Comment(rawValue:
                "свежий покрывающий пак того же шага обязан "
                + "переиспользоваться без сети"))
        // и при огрублении зума тоже: мельче желаемого — годится
        let coarser = WeatherStore.reusablePack(from: [fine],
                                                viewport: viewport,
                                                desiredStep: 1.0, now: now)
        #expect(coarser == fine)
    }

    @Test func finestOfSuitablePacksWins() {
        let fine = pack(latMin: 24.0, lonMin: 54.0, latMax: 26.0,
                        lonMax: 57.0, step: 0.25, fetchedSecondsAgo: 300)
        let coarse = pack(latMin: 20.0, lonMin: 50.0, latMax: 30.0,
                          lonMax: 60.0, step: 1.0, fetchedSecondsAgo: 60)
        let got = WeatherStore.reusablePack(from: [coarse, fine],
                                            viewport: viewport,
                                            desiredStep: 1.0, now: now)
        #expect(got == fine, "из подходящих берётся самый мелкий шаг")
    }

    @Test func stalePackIsNotReused() {
        // 21 минута: на 60 с старше окна в 20 мин (посчитано руками)
        let stale = pack(latMin: 24.0, lonMin: 54.0, latMax: 26.0,
                         lonMax: 57.0, step: 0.25, fetchedSecondsAgo: 21 * 60)
        let got = WeatherStore.reusablePack(from: [stale], viewport: viewport,
                                            desiredStep: 0.25, now: now)
        #expect(got == nil, Comment(rawValue:
                "протухший пак обязан уступить сети — иначе "
                + "погода замирает навсегда"))
    }

    @Test func packNotCoveringMarginIsNotReused() {
        // bbox точно по вьюпорту: зазор 10% (24.86/25.34) уже не покрыт —
        // у кромки кэш обязан уступить перезакачке, не спорить с ней
        let exact = pack(latMin: 24.9, lonMin: 54.9, latMax: 25.3,
                         lonMax: 55.5, step: 0.25, fetchedSecondsAgo: 300)
        let got = WeatherStore.reusablePack(from: [exact], viewport: viewport,
                                            desiredStep: 0.25, now: now)
        #expect(got == nil)
    }

    @Test func coarserThanDesiredIsNotReused() {
        let coarse = pack(latMin: 20.0, lonMin: 50.0, latMax: 30.0,
                          lonMax: 60.0, step: 1.0, fetchedSecondsAgo: 60)
        let got = WeatherStore.reusablePack(from: [coarse], viewport: viewport,
                                            desiredStep: 0.25, now: now)
        #expect(got == nil, Comment(rawValue:
                "грубый пак не заменяет мелкий: приближение "
                + "обязано докачать деталь"))
    }

    @Test func worldPackAtClampedBoundsCoversWorldViewport() {
        // мировой вьюпорт упирается в ±85/±180 — зазор клэмпится к миру,
        // иначе мировой пак никогда бы не переиспользовался
        let world = pack(latMin: -85, lonMin: -180, latMax: 85,
                         lonMax: 180, step: 16, fetchedSecondsAgo: 300)
        let worldView = RegionBBox(minLat: -80, minLon: -170,
                                   maxLat: 80, maxLon: 170)
        let got = WeatherStore.reusablePack(from: [world], viewport: worldView,
                                            desiredStep: 16, now: now)
        #expect(got == world)
    }

    @Test func cacheKeepsOnePackPerStepAndEvictsOldest() {
        let a = pack(latMin: 24, lonMin: 54, latMax: 26, lonMax: 57,
                     step: 0.25, fetchedSecondsAgo: 600)
        let b = pack(latMin: 10, lonMin: 100, latMax: 12, lonMax: 103,
                     step: 0.25, fetchedSecondsAgo: 60)
        // тот же шаг — новая область вытесняет старую
        let replaced = WeatherStore.caching(b, into: [a])
        #expect(replaced == [b])

        // лимит: самый старый умирает первым
        let steps: [Double] = [0.25, 0.5, 0.75, 1.0]
        var cache: [WeatherPack] = []
        for (i, s) in steps.enumerated() {
            cache = WeatherStore.caching(
                pack(latMin: 24, lonMin: 54, latMax: 26, lonMax: 57,
                     step: s, fetchedSecondsAgo: Double(1000 - i)),
                into: cache, limit: 3)
        }
        #expect(cache.count == 3)
        #expect(!cache.contains { $0.stepDeg == 0.25 },
                "самый старый (шаг 0.25) обязан быть вытеснен")
    }
}
