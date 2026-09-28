import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Модуль-источник и политика давности (Б1). Ожидания посчитаны руками:
// u/v из скорости и направления, сроки от прогона, ведра силы ветра,
// давность 25 часов. Формат чужого API встречается ТОЛЬКО в фикстурах
// этого файла — они имитируют ответ сервиса.
// ============================================================================

nonisolated struct WeatherSourceTests {

    // Сетка 2×2 узла: широты 10 и 10.25, долготы 105 и 105.25
    private var grid: WeatherRemoteSource.Grid {
        WeatherRemoteSource.grid(forViewport: 10.0, lonMin: 105.0,
                                 latMax: 10.25, lonMax: 105.25)
    }

    /// Ответ сервиса на 4 точки (порядок = порядок точек в запросе:
    /// широта внешним циклом). Ось времени: прогон, +1 ч, +3 ч.
    /// Ветер: точка (10,105) — 10 м/с с юга (180° = дует на север),
    /// точка (10,105.25) — 5 м/с с востока (90° = дует на запад),
    /// остальные — штиль. Посчитано руками.
    private func upstreamJSON(runUnix: Double) -> Data {
        let times = [runUnix, runUnix + 3600, runUnix + 10800]
        func location(_ lat: Double, _ lon: Double, dir: Double,
                      speed: Double, temp: Double) -> [String: Any] {
            [
                "latitude": lat, "longitude": lon,
                "hourly": [
                    "time": times,
                    "temperature_2m": [temp, temp, temp],
                    "wind_speed_10m": [speed, speed, speed],
                    "wind_direction_10m": [dir, dir, dir],
                    "cloud_cover": [50.0, 50.0, 50.0],
                    "precipitation": [0.0, 0.3, 2.5],
                ],
            ]
        }
        return try! JSONSerialization.data(withJSONObject: [
            location(10.0, 105.0, dir: 180, speed: 10, temp: 30.5),
            location(10.0, 105.25, dir: 90, speed: 5, temp: 28.0),
            location(10.25, 105.0, dir: 0, speed: 0, temp: 29.0),
            location(10.25, 105.25, dir: 0, speed: 0, temp: 29.0),
        ])
    }

    private let run = 1_754_625_600.0
    private var now: Date { Date(timeIntervalSince1970: run + 7200) }

    @Test("сборка пака: наш формат, сроки кратны 3 ч от прогона")
    func packBuildsInOurFormat() throws {
        let data = try WeatherRemoteSource.packData(
            chunks: [upstreamJSON(runUnix: run)], grid: grid,
            runUnix: run, now: now)
        let pack = try WeatherPack.decode(data, now: now)
        // из трёх времён берутся только кратные 3 ч: +0 и +3
        #expect(pack.hours == [0, 3])
        #expect(pack.model == "icon-13km")
        #expect(pack.runDate == Date(timeIntervalSince1970: run))
        #expect(pack.gridLatCount == 2)
        #expect(pack.gridLonCount == 2)
    }

    @Test("u/v посчитаны из скорости и направления «откуда» — руками")
    func windComponentsHandChecked() throws {
        let data = try WeatherRemoteSource.packData(
            chunks: [upstreamJSON(runUnix: run)], grid: grid,
            runUnix: run, now: now)
        let pack = try WeatherPack.decode(data, now: now)
        // Точка А: ветер С ЮГА (180°) → дует НА СЕВЕР: u=0, v=+10 м/с
        #expect(WeatherRender.value(pack, field: "wind_u10",
                                    hourIdx: 0, latIdx: 0, lonIdx: 0) == 0)
        #expect(WeatherRender.value(pack, field: "wind_v10",
                                    hourIdx: 0, latIdx: 0, lonIdx: 0) == 10)
        // Точка Б: ветер С ВОСТОКА (90°) → дует НА ЗАПАД: u=−5, v=0
        #expect(WeatherRender.value(pack, field: "wind_u10",
                                    hourIdx: 0, latIdx: 0, lonIdx: 1) == -5)
        #expect(WeatherRender.value(pack, field: "wind_v10",
                                    hourIdx: 0, latIdx: 0, lonIdx: 1) == 0)
        // Куда-азимуты: 0° (север) и 270° (запад)
        #expect(WeatherRender.bearing(u: 0, v: 10) == 0)
        #expect(WeatherRender.bearing(u: -5, v: 0) == 270)
    }

    @Test("сетка вьюпорта: шаг растёт с областью, точек не больше ~440")
    func gridStepScalesWithViewport() {
        let small = WeatherRemoteSource.grid(forViewport: 10, lonMin: 105,
                                             latMax: 11, lonMax: 106)
        #expect(small.step == 0.25)
        let big = WeatherRemoteSource.grid(forViewport: 5, lonMin: 100,
                                           latMax: 25, lonMax: 120)
        #expect(big.step >= 1.0)
        // потолок точек (починка 06.08): обзорные зумы грузятся быстро
        #expect(big.lats.count * big.lons.count <= 300)
        // мировой зум: ВЕСЬ мир в один пак (~290 точек, 8 вызовов)
        let world = WeatherRemoteSource.grid(forViewport: -85, lonMin: -180,
                                             latMax: 85, lonMax: 180)
        #expect(world.lats.count * world.lons.count <= 300)
        #expect(world.step <= 16)
        #expect(world.latMax - world.latMin >= 160)   // покрыта вся планета
    }

    @Test("мировая сетка с клэмпом ±85: пак собирается и декодится")
    func worldClampedGridPackDecodes() throws {
        // Регресс 06.08: bbox писался по заявленным углам (85), а узлы
        // клэмп делал некратными шагу (последний 75) — декодер честно
        // отвечал sizeMismatch. Теперь bbox — по фактическим узлам.
        let g = WeatherRemoteSource.grid(forViewport: -85, lonMin: -180,
                                         latMax: 85, lonMax: 180)
        let times = [run, run + 10800]
        let locations: [[String: Any]] = g.lats.flatMap { lat in
            g.lons.map { lon in
                ["latitude": lat, "longitude": lon,
                 "hourly": [
                    "time": times,
                    "temperature_2m": [20.0, 20.0],
                    "wind_speed_10m": [1.0, 1.0],
                    "wind_direction_10m": [0.0, 0.0],
                    "cloud_cover": [0.0, 0.0],
                    "precipitation": [0.0, 0.0]]] as [String: Any]
            }
        }
        let chunk = try JSONSerialization.data(withJSONObject: locations)
        let data = try WeatherRemoteSource.packData(
            chunks: [chunk], grid: g, runUnix: run, now: now)
        let pack = try WeatherPack.decode(data, now: now)
        #expect(pack.gridLatCount == g.lats.count)
        #expect(pack.gridLonCount == g.lons.count)
        #expect(pack.latMax <= 85 && pack.latMax == g.lats.last!)
    }

    @Test("края мира дотягиваются: мировой пак рисуется до ±85/±180")
    func drawBoundsReachWorldEdges() throws {
        // мировая сетка шагом 16°: узлы до 75/172 — зазор меньше шага,
        // отрисовка обязана дойти до краёв (шов и «пустая Гренландия»)
        let g = WeatherRemoteSource.grid(forViewport: -85, lonMin: -180,
                                         latMax: 85, lonMax: 180)
        let count = 1 * g.lats.count * g.lons.count
        let root: [String: Any] = [
            "format": "chappe.weather.pack", "version": 1,
            "model": "icon-13km", "run_unix": run,
            "fetched_unix": run + 60,
            "bbox": [g.lats.first!, g.lons.first!,
                     g.lats.last!, g.lons.last!],
            "step_deg": g.step, "hours": [72],
            "fields": Dictionary(uniqueKeysWithValues:
                WeatherPack.requiredFields.map {
                    ($0, ["unit": "x", "scale": 1,
                          "values": Array(repeating: 0, count: count)])
                }),
        ]
        let pack = try WeatherPack.decode(
            try JSONSerialization.data(withJSONObject: root), now: now)
        let b = WeatherRender.drawBounds(pack)
        #expect(b.latMin == -85 && b.latMax == 85)
        #expect(b.lonMin == -180 && b.lonMax == 180)
        // региональный пак не дотягивается — его края далеко от мира
        let regional = try WeatherPack.decode(try JSONSerialization.data(
            withJSONObject: {
                var r = root
                r["bbox"] = [10.0, 105.0, 10.25, 105.25]
                r["step_deg"] = 0.25
                let c = 1 * 2 * 2
                r["fields"] = Dictionary(uniqueKeysWithValues:
                    WeatherPack.requiredFields.map {
                        ($0, ["unit": "x", "scale": 1,
                              "values": Array(repeating: 0, count: c)])
                    })
                return r
            }()), now: now)
        let rb = WeatherRender.drawBounds(regional)
        #expect(rb.latMin == 10.0 && rb.lonMax == 105.25)
    }

    @Test("null в рядах сервиса (полярные точки) не роняет пак")
    func nullsInUpstreamSeriesBecomeZero() throws {
        // Регресс 07.08: мировой пак включает полярные широты, где
        // сервис отдаёт null — разбор обязан дать 0, а не отказ
        let times = [run, run + 10800]
        func location(_ lat: Double, _ lon: Double) -> [String: Any] {
            ["latitude": lat, "longitude": lon,
             "hourly": [
                "time": times,
                "temperature_2m": [NSNull(), 20.0],
                "wind_speed_10m": [5.0, NSNull()],
                "wind_direction_10m": [90.0, 90.0],
                "cloud_cover": [NSNull(), NSNull()],
                "precipitation": [0.0, 0.1]]] as [String: Any]
        }
        let g = grid
        let locations = g.lats.flatMap { lat in
            g.lons.map { lon in location(lat, lon) }
        }
        let chunk = try JSONSerialization.data(withJSONObject: locations)
        let data = try WeatherRemoteSource.packData(
            chunks: [chunk], grid: g, runUnix: run, now: now)
        let pack = try WeatherPack.decode(data, now: now)
        // null-температура срока 0 → 0
        #expect(WeatherRender.value(pack, field: "temp_2m",
                                    hourIdx: 0, latIdx: 0, lonIdx: 0) == 0)
        // живая температура срока +3 сохранена
        #expect(WeatherRender.value(pack, field: "temp_2m",
                                    hourIdx: 1, latIdx: 0, lonIdx: 0) == 20)
    }

    @MainActor
    @Test("род сбоя: «нет сети» только при офлайне, не при отказе сервиса")
    func fetchErrorNamesRealCause() {
        // Полевой урок 07.08: бейдж писал «нет сети» при живом Wi-Fi,
        // когда сервис отвечал 429
        #expect(WeatherStore.fetchErrorLine(
            for: URLError(.notConnectedToInternet)) == "нет сети")
        #expect(WeatherStore.fetchErrorLine(
            for: URLError(.timedOut)) == "сервис не отвечает")
        #expect(WeatherStore.fetchErrorLine(
            for: WeatherRemoteSource.SourceError.badUpstream("429"))
            == "сервис погоды не ответил")
    }

    @Test("ведра силы ветра: границы 4 и 9 м/с")
    func windBuckets() {
        #expect(WeatherRender.windBucket(3.9) == 0)
        #expect(WeatherRender.windBucket(4.0) == 1)
        #expect(WeatherRender.windBucket(8.9) == 1)
        #expect(WeatherRender.windBucket(9.0) == 2)
    }
}

// MARK: - Политика давности стора

nonisolated struct WeatherFreshnessTests {

    private func pack(runAgoHours: Double, horizon: Int,
                      now: Date) throws -> WeatherPack {
        let run = now.addingTimeInterval(-runAgoHours * 3600)
        let eight = Array(repeating: 1, count: 2 * 2 * 1)
        let root: [String: Any] = [
            "format": "chappe.weather.pack", "version": 1,
            "model": "icon-13km",
            "run_unix": run.timeIntervalSince1970,
            "fetched_unix": run.timeIntervalSince1970 + 60,
            "bbox": [10.0, 105.0, 10.25, 105.25],
            "step_deg": 0.25,
            "hours": [horizon],
            "fields": Dictionary(uniqueKeysWithValues:
                WeatherPack.requiredFields.map {
                    ($0, ["unit": "x", "scale": 1, "values": eight])
                }),
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        return try WeatherPack.decode(data, now: now)
    }

    @MainActor
    @Test("25 часов от прогона — показываем, но с пометкой «старые»")
    func staleAfter24Hours() throws {
        let now = Date(timeIntervalSince1970: 1_754_650_800)
        // горизонт 72 ч — сроки ещё впереди, но прогону 25 ч
        let store = WeatherStore(testPack:
            try pack(runAgoHours: 25, horizon: 72, now: now))
        #expect(store.freshness(now: now) == .stale(hours: 25))
        let line = try #require(store.ageLine(now: now))
        #expect(line.contains("данные старые"))
        #expect(store.canRenderAt(now: now))   // показываем, не прячем
    }

    @MainActor
    @Test("сроки пака позади — слои не рисуются, плашка честная")
    func beyondHorizonRefusesRender() throws {
        let now = Date(timeIntervalSince1970: 1_754_650_800)
        // прогон 10 ч назад, горизонт всего +6 ч → всё позади
        let store = WeatherStore(testPack:
            try pack(runAgoHours: 10, horizon: 6, now: now))
        #expect(store.freshness(now: now) == .beyondHorizon)
        #expect(!store.canRenderAt(now: now))
        let line = try #require(store.ageLine(now: now))
        #expect(line.contains("нужна сеть"))
    }

    @MainActor
    @Test("свежий прогон — обычная пометка без тревоги")
    func freshPackIsCalm() throws {
        let now = Date(timeIntervalSince1970: 1_754_650_800)
        let store = WeatherStore(testPack:
            try pack(runAgoHours: 3, horizon: 72, now: now))
        #expect(store.freshness(now: now) == .fresh(hours: 3))
        #expect(store.canRenderAt(now: now))
    }
}

// MARK: - Политика следования за областью (переделка 06.08)

nonisolated struct WeatherViewportPolicyTests {

    /// Пак, скачанный с запасом вокруг вьюпорта 10..11 / 105..106
    /// (paddedFetchBBox: +50% на сторону → 9.5..11.5 / 104.5..106.5).
    private func packAround() throws -> WeatherPack {
        let bbox = WeatherStore.paddedFetchBBox(RegionBBox(
            minLat: 10, minLon: 105, maxLat: 11, maxLon: 106))
        let grid = WeatherRemoteSource.grid(
            forViewport: bbox.minLat, lonMin: bbox.minLon,
            latMax: bbox.maxLat, lonMax: bbox.maxLon)
        let count = 1 * grid.lats.count * grid.lons.count
        let root: [String: Any] = [
            "format": "chappe.weather.pack", "version": 1,
            "model": "icon-13km",
            "run_unix": 1_754_625_600,
            "fetched_unix": 1_754_625_700,
            "bbox": [grid.latMin, grid.lonMin, grid.latMax, grid.lonMax],
            "step_deg": grid.step,
            "hours": [72],
            "fields": Dictionary(uniqueKeysWithValues:
                WeatherPack.requiredFields.map {
                    ($0, ["unit": "x", "scale": 1,
                          "values": Array(repeating: 0, count: count)])
                }),
        ]
        return try WeatherPack.decode(
            try JSONSerialization.data(withJSONObject: root),
            now: Date(timeIntervalSince1970: 1_754_650_800))
    }

    private let now = Date(timeIntervalSince1970: 1_754_650_800)

    @Test("панорамирование внутри запаса — ни одной закачки")
    func panInsidePaddingIsFree() throws {
        let pack = try packAround()
        // сдвиг на 30% экрана вправо — всё ещё внутри запаса
        let shifted = RegionBBox(minLat: 10, minLon: 105.3,
                                 maxLat: 11, maxLon: 106.3)
        #expect(!WeatherStore.decideRefetch(
            pack: pack, viewport: shifted, now: now, lastFetch: nil))
    }

    @Test("уход за запас — перезакачка")
    func panBeyondPaddingRefetches() throws {
        let pack = try packAround()
        let far = RegionBBox(minLat: 10, minLon: 106.4,
                             maxLat: 11, maxLon: 107.4)
        #expect(WeatherStore.decideRefetch(
            pack: pack, viewport: far, now: now, lastFetch: nil))
    }

    @Test("чаще раза в 15 с не качаем (кроме полного выхода за пак)")
    func minIntervalHolds() throws {
        let pack = try packAround()
        let far = RegionBBox(minLat: 10, minLon: 106.4,
                             maxLat: 11, maxLon: 107.4)
        let justFetched = now.addingTimeInterval(-5)
        #expect(!WeatherStore.decideRefetch(
            pack: pack, viewport: far, now: now, lastFetch: justFetched))
        // но полностью чужая область качается сразу
        let elsewhere = RegionBBox(minLat: -9, minLon: 114,
                                   maxLat: -8, maxLon: 115)
        #expect(WeatherStore.decideRefetch(
            pack: pack, viewport: elsewhere, now: now,
            lastFetch: justFetched))
    }

    @Test("шкалы: цвет заливки и легенды из одних опорных точек")
    func legendMatchesFill() {
        for layer in WeatherLayer.allCases {
            let stops = WeatherRender.legendStops(for: layer)
            for stop in stops {
                let c = WeatherRender.color(for: layer, value: stop.value)
                #expect(c.r == stop.color.r && c.g == stop.color.g
                        && c.b == stop.color.b,
                        "\(layer) @ \(stop.value)")
            }
        }
    }

    @Test("мировой вьюпорт: закачка покрывает весь мир, не окно")
    func worldFetchCoversWorld() {
        let world = RegionBBox(minLat: -60, minLon: -170,
                               maxLat: 60, maxLon: 170)
        let t = WeatherStore.paddedFetchBBox(world)
        #expect(t.minLat == -85 && t.maxLat == 85)
        #expect(t.minLon == -180 && t.maxLon == 180)
    }

    @Test("шаг сетки стрелок: ~9 на ось, прищёлкнут к красивым значениям")
    func arrowSpacingIsNice() {
        #expect(WeatherRender.arrowSpacing(forSpan: 0.9) == 0.1)
        #expect(WeatherRender.arrowSpacing(forSpan: 4.5) == 0.5)
        #expect(WeatherRender.arrowSpacing(forSpan: 18) == 2)
    }
}

// МЕГА-12 (14.08): сюита не смеет зависеть от квоты open-meteo.
// Слом: сломать makeStubPack (поля/формат) — красный; убрать гейт
// сети при stubAsked — Wind-приёмки снова пойдут в сеть и лягут
// на квоте (ловится их прогоном).
nonisolated struct WeatherStubTests {

    @MainActor
    @Test("синтетический пак жив: все поля, мир, рендер без сети")
    func stubPackIsRenderable() throws {
        let now = Date()
        let pack = try #require(WeatherStore.makeStubPack(now: now),
                                "стаб обязан собираться")
        for field in WeatherPack.requiredFields {
            #expect(pack.fields[field] != nil, Comment(rawValue:
                    "поле \(field) обязано быть — без него слой падает"))
        }
        let store = WeatherStore(testPack: pack)
        #expect(store.canRenderAt(now: now), Comment(rawValue:
                "стаб обязан рендериться сразу — на нём держится "
                + "детерминированность Wind-приёмок (мега-12)"))
        // JSON-раундтрип Double теряет ULP: возраст бывает ~1e-7 ч
        if case .fresh(let hours)? = store.freshness(now: now) {
            #expect(hours < 0.01, "стаб свеж «сейчас»")
        } else {
            Issue.record("стаб обязан быть свежим")
        }
    }
}
