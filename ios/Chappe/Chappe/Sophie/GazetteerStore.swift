import Foundation

// ============================================================================
// GazetteerStore — офлайн-справочник населённых пунктов (Resources/geo/
// gazetteer.bin, собран tools/geo/build_gazetteer.py из GeoNames, CC-BY 4.0).
//
// Координаты → ближайший пункт (линейный перебор по гаверсинусу, ~235 тыс.
// записей, целевая скорость <50 мс) и поиск по точному имени без регистра
// (для distance_eta). Никакого другого геокодинга не изобретаем.
// ============================================================================

nonisolated struct GazetteerHit: Sendable, Equatable {
    let name: String
    let country: String
    let lat: Double
    let lon: Double
    let population: UInt32
    /// Расстояние от запрошенной точки, км (для find — 0).
    var distanceKm: Double = 0
    /// Начальный азимут ОТ пункта К запрошенной точке, градусы 0–360.
    var bearingDeg: Double = 0
}

nonisolated final class GazetteerStore: @unchecked Sendable {

    static let shared = GazetteerStore()

    private let lock = NSLock()
    private var loaded = false
    private var lats: [Double] = []
    private var lons: [Double] = []
    private var pops: [UInt32] = []
    private var countryIdx: [UInt16] = []
    private var names: [String] = []
    private var countries: [String] = []

    var count: Int {
        ensureLoaded()
        return names.count
    }

    // MARK: Загрузка (лениво, потокобезопасно)

    private func ensureLoaded() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "gazetteer",
                                        withExtension: "bin",
                                        subdirectory: "geo")
                ?? Bundle.main.url(forResource: "gazetteer", withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return   // нет файла — все запросы вернут пусто, Софи скажет честно
        }
        parse(data)
    }

    private func parse(_ d: Data) {
        var off = d.startIndex
        func u8() -> Int { defer { off += 1 }; return Int(d[off]) }
        func u16() -> Int {
            defer { off += 2 }
            return Int(d[off]) | Int(d[off + 1]) << 8
        }
        func i32() -> Int32 {
            defer { off += 4 }
            return Int32(bitPattern:
                UInt32(d[off]) | UInt32(d[off + 1]) << 8
                | UInt32(d[off + 2]) << 16 | UInt32(d[off + 3]) << 24)
        }
        func str(_ len: Int) -> String {
            defer { off += len }
            return String(decoding: d[off..<off + len], as: UTF8.self)
        }

        guard d.count > 11, str(4) == "RMGZ", u8() == 1 else { return }
        let ncountries = u16()
        countries.reserveCapacity(ncountries)
        for _ in 0..<ncountries {
            countries.append(str(u8()))
        }
        let n = Int(UInt32(bitPattern: i32()))
        lats.reserveCapacity(n); lons.reserveCapacity(n)
        pops.reserveCapacity(n); countryIdx.reserveCapacity(n)
        names.reserveCapacity(n)
        for _ in 0..<n {
            lats.append(Double(i32()) / 1e5)
            lons.append(Double(i32()) / 1e5)
            pops.append(UInt32(bitPattern: i32()))
            countryIdx.append(UInt16(u16()))
            names.append(str(u8()))
        }
    }

    // MARK: Запросы

    /// Ближайший пункт к точке. Линейный перебор, но ранжирование —
    /// дешёвой равнопрямоугольной метрикой (без тригонометрии в цикле,
    /// долгота обёрнута на ±180°); точный гаверсинус считается один раз,
    /// для победителя. Для поиска ближайшего этого достаточно.
    func nearest(lat: Double, lon: Double) -> GazetteerHit? {
        ensureLoaded()
        guard !lats.isEmpty else { return nil }
        let cosq = cos(lat * .pi / 180)
        var bestIndex = 0
        var bestMetric = Double.greatestFiniteMagnitude
        lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in
                for i in 0..<la.count {
                    let dy = la[i] - lat
                    var dx = lo[i] - lon
                    if dx > 180 { dx -= 360 } else if dx < -180 { dx += 360 }
                    dx *= cosq
                    let metric = dy * dy + dx * dx
                    if metric < bestMetric {
                        bestMetric = metric
                        bestIndex = i
                    }
                }
            }
        }
        let km = SophieTools.haversineKm(lat1: lat, lon1: lon,
                                       lat2: lats[bestIndex], lon2: lons[bestIndex])
        return hit(at: bestIndex, distanceKm: km,
                   bearing: Self.bearing(fromLat: lats[bestIndex],
                                         fromLon: lons[bestIndex],
                                         toLat: lat, toLon: lon))
    }

    /// Точное совпадение имени без регистра; сортировка по населению ↓
    /// (для уточнения при неоднозначности).
    /// Ф1.3 (30.07): имена пунктов рядом с точкой — подсказка лексики
    /// для contextualStrings STT. Весь справочник (GeoNames) кормить
    /// нельзя — Apple рекомендует сотни строк; берём ближайшие по
    /// равнопрямоугольной метрике, крупные по населению — первыми.
    func namesNear(lat: Double, lon: Double,
                   radiusKm: Double = 300, limit: Int = 200) -> [String] {
        ensureLoaded()
        guard !names.isEmpty else { return [] }
        let cosLat = cos(lat * .pi / 180)
        let degRadius = radiusKm / 111.0
        var picked: [(pop: UInt32, name: String)] = []
        for i in 0..<names.count {
            let dLat = lats[i] - lat
            var dLon = lons[i] - lon
            if dLon > 180 { dLon -= 360 }
            if dLon < -180 { dLon += 360 }
            dLon *= cosLat
            if dLat * dLat + dLon * dLon <= degRadius * degRadius {
                picked.append((pops[i], names[i]))
            }
        }
        return picked.sorted { $0.pop > $1.pop }
            .prefix(limit).map(\.name)
    }

    func find(name: String) -> [GazetteerHit] {
        ensureLoaded()
        let needle = name.lowercased()
        var found: [GazetteerHit] = []
        for i in 0..<names.count where names[i].lowercased() == needle {
            found.append(hit(at: i, distanceKm: 0, bearing: 0))
        }
        return found.sorted { $0.population > $1.population }
    }

    /// Поиск с допуском в одну букву (опечатки и варианты написания:
    /// «Касабланка» ↔ «Казабланка»). НЕ геокодинг: детерминированная
    /// правка расстояния Левенштейна ≤ 1 к точному матчу.
    /// corrected=true — имя было поправлено (Софи обязана это назвать).
    func findFuzzy(name: String) -> (hits: [GazetteerHit], corrected: Bool) {
        let exact = find(name: name)
        if !exact.isEmpty { return (exact, false) }
        ensureLoaded()
        let needle = Array(name.lowercased())
        var found: [GazetteerHit] = []
        for i in 0..<names.count {
            let candidate = names[i]
            guard abs(candidate.count - needle.count) <= 1 else { continue }
            if Self.editDistanceAtMostOne(needle, Array(candidate.lowercased())) {
                found.append(hit(at: i, distanceKm: 0, bearing: 0))
            }
        }
        return (found.sorted { $0.population > $1.population }, !found.isEmpty)
    }

    /// Расстояние Левенштейна ≤ 1 за один проход.
    static func editDistanceAtMostOne(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard long.count - short.count <= 1 else { return false }
        var i = 0, j = 0
        var edits = 0
        while i < short.count && j < long.count {
            if short[i] == long[j] {
                i += 1; j += 1
            } else {
                edits += 1
                if edits > 1 { return false }
                if short.count == long.count {
                    i += 1; j += 1   // замена
                } else {
                    j += 1           // вставка в длинном
                }
            }
        }
        return edits + (long.count - j) <= 1
    }

    private func hit(at i: Int, distanceKm: Double, bearing: Double) -> GazetteerHit {
        GazetteerHit(name: names[i],
                     country: countries[Int(countryIdx[i])],
                     lat: lats[i], lon: lons[i],
                     population: pops[i],
                     distanceKm: distanceKm, bearingDeg: bearing)
    }

    // MARK: Контейнерный поиск (баг полевого теста: ближайший центр
    // побеждал мегаполис — учитываем площадь города через радиус)

    /// Оценка радиуса пункта по населению: 0.01·√pop, кламп [2, 30] км.
    static func radiusKm(population: UInt32) -> Double {
        min(30, max(2, 0.01 * Double(population).squareRoot()))
    }

    nonisolated struct Context: Sendable {
        /// Пункт, ВНУТРИ которого точка (dist ≤ radius); из таких — самый
        /// населённый. nil — точка вне всех радиусов.
        let container: GazetteerHit?
        /// Топ-5 ближайших по расстоянию (включая контейнер, если попал).
        let candidates: [GazetteerHit]
    }

    /// Полный геоконтекст точки: контейнер + топ-5 кандидатов.
    func locate(lat: Double, lon: Double) -> Context {
        ensureLoaded()
        guard !lats.isEmpty else { return Context(container: nil, candidates: []) }
        let cosq = cos(lat * .pi / 180)

        var top: [(metricKm: Double, index: Int)] = []   // топ-5, отсортирован
        var containerIndex = -1
        var containerPop: UInt32 = 0

        lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in
                pops.withUnsafeBufferPointer { po in
                    for i in 0..<la.count {
                        let dy = la[i] - lat
                        var dx = lo[i] - lon
                        if dx > 180 { dx -= 360 } else if dx < -180 { dx += 360 }
                        dx *= cosq
                        // дешёвая метрика сразу в километрах (экviрект)
                        let km = (dy * dy + dx * dx).squareRoot() * 111.19

                        if top.count < 5 || km < top[top.count - 1].metricKm {
                            top.append((km, i))
                            top.sort { $0.metricKm < $1.metricKm }
                            if top.count > 5 { top.removeLast() }
                        }
                        // контейнер: точка внутри радиуса пункта;
                        // из нескольких берём самый населённый
                        if km <= Self.radiusKm(population: po[i]),
                           po[i] > containerPop {
                            containerPop = po[i]
                            containerIndex = i
                        }
                    }
                }
            }
        }

        let candidates = top.map { item -> GazetteerHit in
            let km = SophieTools.haversineKm(lat1: lat, lon1: lon,
                                           lat2: lats[item.index],
                                           lon2: lons[item.index])
            return hit(at: item.index, distanceKm: km,
                       bearing: Self.bearing(fromLat: lats[item.index],
                                             fromLon: lons[item.index],
                                             toLat: lat, toLon: lon))
        }

        var container: GazetteerHit?
        if containerIndex >= 0 {
            let km = SophieTools.haversineKm(lat1: lat, lon1: lon,
                                           lat2: lats[containerIndex],
                                           lon2: lons[containerIndex])
            if km <= Self.radiusKm(population: pops[containerIndex]) {
                container = hit(at: containerIndex, distanceKm: km,
                                bearing: Self.bearing(
                                    fromLat: lats[containerIndex],
                                    fromLon: lons[containerIndex],
                                    toLat: lat, toLon: lon))
            }
        }
        return Context(container: container, candidates: candidates)
    }

    /// «Северной/южной/…» — часть города по румбу от центра к точке.
    static func partAdjective(_ bearingDeg: Double) -> String {
        let names = ["северной", "северо-восточной", "восточной",
                     "юго-восточной", "южной", "юго-западной",
                     "западной", "северо-западной"]
        let sector = Int(((bearingDeg + 22.5)
                          .truncatingRemainder(dividingBy: 360)) / 45)
        return names[sector]
    }

    /// Формулировка по контексту: внутри города — «в южной части X»
    /// (+ «рядом Y», если малый пункт ближе 8 км); вне — прежнее правило.
    static func phrase(for context: Context) -> String {
        if let city = context.container {
            var text = "в \(partAdjective(city.bearingDeg)) части "
                     + "\(city.name), \(city.country)"
            if let near = context.candidates.first(where: {
                $0.name != city.name && $0.distanceKm < 8
            }) {
                text += ", рядом \(near.name)"
            }
            return text
        }
        guard let nearest = context.candidates.first else {
            return "населённых пунктов в справочнике рядом нет"
        }
        return phrase(for: nearest)
    }

    /// Блок кандидатов для результата инструмента: модель видит все пять.
    static func candidatesBlock(_ context: Context) -> String {
        context.candidates.map { c in
            let inside = context.container?.name == c.name ? "да" : "нет"
            return String(format: "- %@ (%@): %.0f км к %@, нас. %d, внутри: %@",
                          c.name, c.country, c.distanceKm, rumb(c.bearingDeg),
                          c.population, inside)
        }.joined(separator: "\n")
    }

    // MARK: Румбы и формулировки

    /// Начальный азимут от (fromLat,fromLon) к (toLat,toLon), 0–360°.
    static func bearing(fromLat: Double, fromLon: Double,
                        toLat: Double, toLon: Double) -> Double {
        let φ1 = fromLat * .pi / 180, φ2 = toLat * .pi / 180
        let dλ = (toLon - fromLon) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Восемь румбов по-русски.
    static func rumb(_ bearingDeg: Double) -> String {
        let names = ["северу", "северо-востоку", "востоку", "юго-востоку",
                     "югу", "юго-западу", "западу", "северо-западу"]
        let sector = Int(((bearingDeg + 22.5)
                          .truncatingRemainder(dividingBy: 360)) / 45)
        return names[sector]
    }

    /// Правило формулировки: <3 км — «в районе X»; до 50 км — «N км
    /// к <румбу> от X»; дальше — честное «далеко от населённых пунктов».
    static func phrase(for hit: GazetteerHit) -> String {
        let place = "\(hit.name), \(hit.country)"
        if hit.distanceKm < 3 {
            return "в районе \(place)"
        }
        let km = String(format: "%.0f", hit.distanceKm)
        if hit.distanceKm <= 50 {
            return "\(km) км к \(rumb(hit.bearingDeg)) от \(place)"
        }
        return "далеко от населённых пунктов, ближайший — \(place), "
             + "\(km) км к \(rumb(hit.bearingDeg))"
    }
}
