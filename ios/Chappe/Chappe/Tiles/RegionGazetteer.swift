import Foundation

// ============================================================================
// Офлайн-газеттир РЕГИОНОВ (Ф2.2, бриф 31.07): выбор области скачивания
// по имени, с bounding box и локальной оценкой веса. Поставляется в
// бандле (Resources/geo/regions_gazetteer.json), сети не касается —
// сторонние геокодеры (Nominatim и т.п.) не используются сознательно:
// это сетевая зависимость и чужие лимиты, против принципа независимости.
//
// Источники данных (ADR 004): города — GeoNames cities15000 (CC-BY 4.0),
// русские имена — alternateNamesV2 (isolanguage=ru); области — Natural
// Earth 10m admin_1 (public domain), bbox из полигонов. Сборка —
// tools/geo/build_region_gazetteer.py.
// ============================================================================

nonisolated struct RegionSuggestion: Identifiable, Equatable, Sendable {
    let name: String        // русское имя (или основное, если ru нет)
    let nameEn: String
    let country: String
    let isArea: Bool        // false — город, true — область/провинция
    let population: Int     // у областей — условный ключ сортировки
    let bbox: RegionBBox

    var id: String { "\(name)|\(nameEn)|\(country)|\(isArea)" }

    /// Подпись в списке: «Москва, Россия» / «Московская область, Россия».
    var title: String { country.isEmpty ? name : "\(name), \(country)" }
}

/// Загрузка лениво и потокобезопасно; поиск — только по памяти.
nonisolated final class RegionGazetteer: @unchecked Sendable {

    static let shared = RegionGazetteer()

    private let lock = NSLock()
    private var entries: [RegionSuggestion]?

    /// Нормализация запроса и имён: регистр, ё→е.
    private static func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private func loaded() -> [RegionSuggestion] {
        lock.lock(); defer { lock.unlock() }
        if let entries { return entries }
        var result: [RegionSuggestion] = []
        if let url = Bundle.main.url(forResource: "regions_gazetteer",
                                     withExtension: "json",
                                     subdirectory: "geo")
            ?? Bundle.main.url(forResource: "regions_gazetteer",
                               withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data)
               as? [String: Any],
           let rows = obj["entries"] as? [[Any]] {
            result.reserveCapacity(rows.count)
            for row in rows where row.count >= 9 {
                guard let name = row[0] as? String,
                      let nameEn = row[1] as? String,
                      let country = row[2] as? String,
                      let kind = row[3] as? Int,
                      let population = row[4] as? Int,
                      let minLat = Self.double(row[5]),
                      let minLon = Self.double(row[6]),
                      let maxLat = Self.double(row[7]),
                      let maxLon = Self.double(row[8]) else { continue }
                result.append(RegionSuggestion(
                    name: name, nameEn: nameEn, country: country,
                    isArea: kind == 1, population: population,
                    bbox: RegionBBox(minLat: minLat, minLon: minLon,
                                     maxLat: maxLat, maxLon: maxLon)))
            }
        }
        entries = result
        return result
    }

    private static func double(_ any: Any) -> Double? {
        (any as? Double) ?? (any as? Int).map(Double.init)
    }

    /// Автодополнение: префикс по русскому и английскому имени,
    /// сортировка по населению (крупное — выше).
    func search(_ query: String, limit: Int = 6) -> [RegionSuggestion] {
        let q = Self.normalized(
            query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard q.count >= 2 else { return [] }
        return loaded()
            .filter {
                Self.normalized($0.name).hasPrefix(q)
                    || Self.normalized($0.nameEn).hasPrefix(q)
            }
            .sorted {
                $0.population == $1.population
                    ? $0.name < $1.name
                    : $0.population > $1.population
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Имя места по точке (Ф2.5: имя региона по умолчанию — по центру
    /// видимой области). Город, чей bbox содержит точку; из нескольких —
    /// самый населённый. Городов нет — область.
    func name(atLat lat: Double, lon: Double) -> String? {
        let all = loaded()
        let cities = all.filter { !$0.isArea && $0.bbox.contains(lat: lat, lon: lon) }
        if let best = cities.max(by: { $0.population < $1.population }) {
            return best.name
        }
        let areas = all.filter { $0.isArea && $0.bbox.contains(lat: lat, lon: lon) }
        // из областей — самая маленькая по площади (самая конкретная)
        return areas.min { area($0.bbox) < area($1.bbox) }?.name
    }

    private func area(_ b: RegionBBox) -> Double {
        (b.maxLat - b.minLat) * (b.maxLon - b.minLon)
    }
}

// MARK: - Пересечение регионов (Ф2.3: дубли)

extension RegionBBox {
    /// Доля пересечения с другим bbox относительно МЕНЬШЕГО из двух:
    /// «новый пак больше чем наполовину повторяет существующий» —
    /// повод предупредить и предложить заменить.
    func overlapRatio(with other: RegionBBox) -> Double {
        let interMinLat = max(minLat, other.minLat)
        let interMaxLat = min(maxLat, other.maxLat)
        let interMinLon = max(minLon, other.minLon)
        let interMaxLon = min(maxLon, other.maxLon)
        guard interMinLat < interMaxLat, interMinLon < interMaxLon else {
            return 0
        }
        let inter = (interMaxLat - interMinLat) * (interMaxLon - interMinLon)
        let mine = (maxLat - minLat) * (maxLon - minLon)
        let theirs = (other.maxLat - other.minLat) * (other.maxLon - other.minLon)
        let smaller = min(mine, theirs)
        guard smaller > 0 else { return 0 }
        return inter / smaller
    }
}
