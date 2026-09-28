import Foundation

// ============================================================================
// ЕДИНСТВЕННЫЙ файл, знающий про Open-Meteo (docs/weather_pack.md, п.1).
// Имя типа нейтральное НАМЕРЕННО: остальной код ссылается на
// WeatherRemoteSource, и греп-замок ловит само слово «open-meteo»
// в любом другом файле. Переезд Б1 → Б2 переписывает только этот файл.
// Всё чужое — URL, имена их параметров, форма их JSON — живёт здесь и
// не выходит наружу: наружу выходит только наш пак (WeatherPack.decode).
// Замок границы — tools/dev/weather_boundary_lint.py (греп по исходникам).
//
// Контракт свежести: время прогона берётся из мета-эндпоинта модели
// (last_run_initialisation_time) ДО и ПОСЛЕ закачки сетки; если прогон
// сменился во время закачки — данные могли смешаться, цикл повторяется
// один раз, дальше честный отказ. Пак без прогона не собирается вообще.
//
// Лицензия (проверено 06.08.2026): бесплатно для приложений без подписок
// и рекламы; данные CC BY 4.0 — атрибуция обязательна (показывается в
// листе о погодных слоях). При выходе на краудфандинг — переезд на Б2,
// меняется только этот файл.
// ============================================================================

nonisolated enum WeatherRemoteSource {

    enum SourceError: Error, Equatable {
        case runChangedDuringFetch   // прогон сменился во время закачки, и повтор не помог
        case badUpstream(String)     // ответ не разобрался — честно, без домыслов
        /// Сервис попросил паузу (HTTP 429). Секунды — из Retry-After,
        /// если сервис их назвал (честность клиента: не долбить раньше
        /// срока; заказ владельца 08.08 после полевого 429).
        case rateLimited(retryAfter: Double?)
    }

    /// Разбор Retry-After: секунды («120») или HTTP-дата. Мусор — nil.
    static func retryAfterSeconds(_ header: String?,
                                  now: Date = Date()) -> Double? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed) { return max(0, seconds) }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = fmt.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Единственная точка сетевого чтения: код ответа проверяется,
    /// 429 не глотается как «не разобрался».
    private static func load(_ url: URL,
                             session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: retryAfterSeconds(
                    http.value(forHTTPHeaderField: "Retry-After")))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SourceError.badUpstream("HTTP \(http.statusCode)")
            }
        }
        return data
    }

    /// Наша номенклатура → их идентификаторы. Наружу уходит ТОЛЬКО левая
    /// колонка (поле model пака).
    static let ourModel = "icon-13km"

    /// Строка атрибуции для UI (CC BY 4.0 требует указания источника);
    /// UI берёт её готовой и имени сервиса не знает.
    static let attributionLine = "Погода: Open-Meteo (CC BY 4.0)"
    private static let theirForecastModel = "icon_global"
    private static let theirMetaPath = "dwd_icon"

    private static let apiBase = "https://api.open-meteo.com"
    private static let chunkSize = 50      // координат в одном вызове

    // MARK: Сетка под видимую область

    struct Grid: Equatable {
        let latMin, lonMin, latMax, lonMax: Double
        let step: Double
        var lats: [Double] {
            stride(from: latMin, through: latMax + step / 4, by: step).map { $0 }
        }
        var lons: [Double] {
            stride(from: lonMin, through: lonMax + step / 4, by: step).map { $0 }
        }
    }

    /// Видимая область → сетка: шаг растёт с размером области. Потолок
    /// ~300 точек (6 кусков + 2 меты = 8 вызовов): любая область, хоть
    /// весь мир, грузится за одну быструю пачку (шаг до 16° на мировом
    /// зуме — грубо, но на нём пиксель экрана и есть сотни км).
    static func grid(forViewport latMin: Double, lonMin: Double,
                     latMax: Double, lonMax: Double) -> Grid {
        let span = max(latMax - latMin, lonMax - lonMin, 0.5)
        var step = (0.25 * (span / 5.0).rounded(.up))
            .clamped(to: 0.25...2.0)
        func make(_ step: Double) -> Grid {
            func snap(_ v: Double, up: Bool) -> Double {
                (up ? (v / step).rounded(.up)
                    : (v / step).rounded(.down)) * step
            }
            return Grid(latMin: max(snap(latMin, up: false), -85),
                        lonMin: max(snap(lonMin, up: false), -180),
                        latMax: min(snap(latMax, up: true), 85),
                        lonMax: min(snap(lonMax, up: true), 180),
                        step: step)
        }
        var grid = make(step)
        while grid.lats.count * grid.lons.count > 300, step < 16 {
            step *= 2
            grid = make(step)
        }
        return grid
    }

    // MARK: URL (их API — только здесь)

    static func metaURL() -> URL {
        URL(string: "\(apiBase)/data/\(theirMetaPath)/static/meta.json")!
    }

    /// Вызовы прогноза кусками по chunkSize точек (порядок ответа
    /// повторяет порядок координат в запросе — на это опираемся).
    static func forecastURLs(for grid: Grid) -> [URL] {
        let points = grid.lats.flatMap { lat in
            grid.lons.map { lon in (lat, lon) }
        }
        return stride(from: 0, to: points.count, by: chunkSize).map { start in
            let chunk = points[start..<min(start + chunkSize, points.count)]
            let lats = chunk.map { String(format: "%.3f", $0.0) }
                .joined(separator: ",")
            let lons = chunk.map { String(format: "%.3f", $0.1) }
                .joined(separator: ",")
            return URL(string: "\(apiBase)/v1/forecast?latitude=\(lats)"
                + "&longitude=\(lons)"
                + "&hourly=temperature_2m,wind_speed_10m,wind_direction_10m,"
                + "cloud_cover,precipitation"
                + "&models=\(theirForecastModel)&wind_speed_unit=ms"
                + "&timeformat=unixtime&forecast_days=4")!
        }
    }

    // MARK: Сборка нашего пака из их ответов (чистая функция — тестируется)

    /// chunks — сырые Data их вызовов в порядке forecastURLs; runUnix — из
    /// мета-эндпоинта. Возвращает байты НАШЕГО пака (chappe.weather.pack).
    static func packData(chunks: [Data], grid: Grid, runUnix: Double,
                         now: Date) throws -> Data {
        // их JSON: массив локаций (или одна локация словарём)
        var locations: [[String: Any]] = []
        for data in chunks {
            let parsed = try? JSONSerialization.jsonObject(with: data)
            if let array = parsed as? [[String: Any]] {
                locations += array
            } else if let one = parsed as? [String: Any], one["hourly"] != nil {
                locations.append(one)
            } else {
                throw SourceError.badUpstream("ответ прогноза не разобрался")
            }
        }
        let nLat = grid.lats.count, nLon = grid.lons.count
        guard locations.count == nLat * nLon else {
            throw SourceError.badUpstream(
                "точек в ответе \(locations.count), ждали \(nLat * nLon)")
        }

        // Сроки: каждые 3 часа от прогона, от «час назад» и на 72 ч вперёд
        guard let firstHourly = locations.first?["hourly"] as? [String: Any],
              let times = firstHourly["time"] as? [Double]
                ?? (firstHourly["time"] as? [Int]).map({ $0.map(Double.init) })
        else { throw SourceError.badUpstream("нет оси времени") }
        let pickedIdx: [Int] = times.indices.filter { i in
            let offset = times[i] - runUnix
            return offset >= 0
                && offset.truncatingRemainder(dividingBy: 10800) == 0
                && times[i] >= now.timeIntervalSince1970 - 3600 * 3
                && offset <= 72 * 3600
        }
        guard !pickedIdx.isEmpty else {
            throw SourceError.badUpstream("нет сроков в горизонте")
        }
        let hours = pickedIdx.map { Int((times[$0] - runUnix) / 3600) }

        // их ряды → наши поля (u/v из скорости и метеонаправления «откуда»)
        func series(_ loc: [String: Any], _ key: String) throws -> [Double] {
            // сервис отдаёт null в рядах (полярные точки мирового
            // пака!) — null честно превращается в 0, а не роняет пак
            guard let hourly = loc["hourly"] as? [String: Any],
                  let raw = hourly[key] as? [Any]
            else { throw SourceError.badUpstream("нет ряда \(key)") }
            return raw.map {
                ($0 as? Double) ?? ($0 as? Int).map(Double.init) ?? 0
            }
        }
        var u10: [Int] = [], v10: [Int] = [], t2m: [Int] = []
        var cloud: [Int] = [], precip: [Int] = []
        for i in pickedIdx {
            for loc in locations {
                let speed = try series(loc, "wind_speed_10m")[i]
                let dirDeg = try series(loc, "wind_direction_10m")[i]
                let rad = dirDeg * .pi / 180
                u10.append(Int((-speed * sin(rad) * 10).rounded()))
                v10.append(Int((-speed * cos(rad) * 10).rounded()))
                t2m.append(Int((try series(loc, "temperature_2m")[i] * 10).rounded()))
                cloud.append(Int(try series(loc, "cloud_cover")[i].rounded()))
                precip.append(Int((try series(loc, "precipitation")[i] * 10).rounded()))
            }
        }

        // bbox — по ФАКТИЧЕСКИМ крайним узлам, не по заявленным углам:
        // при клэмпе к ±85/±180 сетка теряет кратность шагу, и bbox по
        // углам дал бы sizeMismatch у декодера (найдено на мировом
        // зуме 06.08)
        let root: [String: Any] = [
            "format": "chappe.weather.pack",
            "version": 1,
            "model": ourModel,
            "run_unix": runUnix,
            "fetched_unix": now.timeIntervalSince1970,
            "bbox": [grid.lats.first ?? grid.latMin,
                     grid.lons.first ?? grid.lonMin,
                     grid.lats.last ?? grid.latMax,
                     grid.lons.last ?? grid.lonMax],
            "step_deg": grid.step,
            "hours": hours,
            "fields": [
                "wind_u10": ["unit": "m/s", "scale": 0.1, "values": u10],
                "wind_v10": ["unit": "m/s", "scale": 0.1, "values": v10],
                "temp_2m": ["unit": "C", "scale": 0.1, "values": t2m],
                "cloud_total": ["unit": "%", "scale": 1, "values": cloud],
                "precip": ["unit": "mm/h", "scale": 0.1, "values": precip],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }

    // MARK: Закачка целиком (сеть — URLSession, вся политика прогона здесь)

    struct FetchResult {
        let pack: Data           // байты нашего пака
        let downloadedBytes: Int // сколько скачано у них (для отчёта)
        let calls: Int
        let seconds: Double
    }

    static func fetch(grid: Grid,
                      session: URLSession = .shared) async throws -> FetchResult {
        let started = Date()
        var attempt = 0
        while true {
            attempt += 1
            let runBefore = try await lastRun(session: session)
            // куски качаются ПАРАЛЛЕЛЬНО (починка 06.08: последовательные
            // 9–11 вызовов давали 11+ с — «зависшую» старую область);
            // порядок восстанавливается по индексу
            let urls = forecastURLs(for: grid)
            var indexed: [(Int, Data)] = []
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (i, url) in urls.enumerated() {
                    group.addTask {
                        (i, try await load(url, session: session))
                    }
                }
                for try await item in group { indexed.append(item) }
            }
            let chunks = indexed.sorted { $0.0 < $1.0 }.map(\.1)
            let downloaded = chunks.reduce(0) { $0 + $1.count }
            let runAfter = try await lastRun(session: session)
            if runBefore == runAfter {
                let pack = try packData(chunks: chunks, grid: grid,
                                        runUnix: runBefore, now: Date())
                return FetchResult(
                    pack: pack, downloadedBytes: downloaded,
                    calls: forecastURLs(for: grid).count + 2,
                    seconds: Date().timeIntervalSince(started))
            }
            // прогон сменился под ногами: один повтор, дальше честный отказ
            guard attempt < 2 else { throw SourceError.runChangedDuringFetch }
        }
    }

    private static func lastRun(session: URLSession) async throws -> Double {
        let data = try await load(metaURL(), session: session)
        guard let meta = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let run = meta["last_run_initialisation_time"] as? Double
                ?? (meta["last_run_initialisation_time"] as? Int)
                    .map(Double.init) else {
            throw SourceError.badUpstream("мета без времени прогона")
        }
        return run
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
