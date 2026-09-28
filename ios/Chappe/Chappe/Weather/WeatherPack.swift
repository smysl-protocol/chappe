import Foundation

// ============================================================================
// Погодный пак — НАШ формат (docs/weather_pack.md, решения владельца 06.08).
//
// Два несущих правила:
// 1. Формат не знает про внешний источник: имена, единицы, порядок —
//    свои. Чужой API разбирает единственный модуль-источник (см.
//    tools/dev/weather_boundary_lint.py); хранилище, рендер и UI видят
//    только WeatherPack.
// 2. Свежесть — контракт: пак без времени прогона модели отвергается
//    целиком. Возраст считается ТОЛЬКО от прогона (runDate), никогда
//    от закачки (fetchedDate — диагностика «сети не было», не возраст).
// ============================================================================

nonisolated struct WeatherPack: Sendable, Equatable {

    struct Field: Sendable, Equatable {
        let unit: String
        let scale: Double
        /// Квантованные целые; физическое значение = value × scale.
        /// Порядок: срок → широта (с юга) → долгота (с запада).
        let values: [Int]
    }

    let model: String            // наша номенклатура: gfs-0p25, icon-13km…
    let runDate: Date            // время прогона модели (issue time)
    let fetchedDate: Date        // когда получено; в возрасте НЕ участвует
    let latMin: Double, lonMin: Double, latMax: Double, lonMax: Double
    let stepDeg: Double
    let hours: [Int]             // смещения сроков от прогона, часы
    let fields: [String: Field]

    /// Обязательные поля v1 — все пять слоёв.
    static let requiredFields = ["wind_u10", "wind_v10", "temp_2m",
                                 "cloud_total", "precip"]

    var gridLatCount: Int { Int(((latMax - latMin) / stepDeg).rounded()) + 1 }
    var gridLonCount: Int { Int(((lonMax - lonMin) / stepDeg).rounded()) + 1 }

    /// Возраст прогноза в часах НА МОМЕНТ now — от прогона модели.
    func ageHours(now: Date) -> Double {
        now.timeIntervalSince(runDate) / 3600
    }

    // MARK: Разбор и контракт

    enum DecodeError: Error, Equatable {
        case notAPack                 // не наш формат / не та версия
        case missingRunTime           // нет времени прогона — пак не принимается
        case implausibleRunTime       // прогон раньше 2020 или в будущем
        case fetchedBeforeRun         // получено раньше, чем посчитано
        case badGrid                  // кривой bbox/шаг
        case badHours                 // сроки пусты или не возрастают
        case missingField(String)     // нет обязательного слоя
        case sizeMismatch(String)     // длина поля не сходится с сеткой
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> WeatherPack {
        guard let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              root["format"] as? String == "chappe.weather.pack",
              root["version"] as? Int == 1 else {
            throw DecodeError.notAPack
        }
        // Свежесть — контракт (правило 2 владельца): без времени прогона
        // пак не существует. Лучше отсутствие погоды, чем прогноз без
        // возраста.
        guard let runUnix = root["run_unix"] as? Double
                ?? (root["run_unix"] as? Int).map(Double.init) else {
            throw DecodeError.missingRunTime
        }
        let run = Date(timeIntervalSince1970: runUnix)
        let year2020 = Date(timeIntervalSince1970: 1_577_836_800)
        guard run >= year2020, run <= now.addingTimeInterval(3600) else {
            throw DecodeError.implausibleRunTime
        }
        guard let fetchedUnix = root["fetched_unix"] as? Double
                ?? (root["fetched_unix"] as? Int).map(Double.init),
              fetchedUnix >= runUnix else {
            throw DecodeError.fetchedBeforeRun
        }
        guard let bbox = root["bbox"] as? [Double], bbox.count == 4,
              let step = root["step_deg"] as? Double, step > 0,
              bbox[0] >= -90, bbox[2] <= 90, bbox[0] < bbox[2],
              bbox[1] >= -180, bbox[3] <= 180, bbox[1] < bbox[3] else {
            throw DecodeError.badGrid
        }
        guard let hours = root["hours"] as? [Int], !hours.isEmpty,
              hours.first! >= 0,
              zip(hours, hours.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw DecodeError.badHours
        }
        let pack = WeatherPack(
            model: root["model"] as? String ?? "unknown",
            runDate: run,
            fetchedDate: Date(timeIntervalSince1970: fetchedUnix),
            latMin: bbox[0], lonMin: bbox[1],
            latMax: bbox[2], lonMax: bbox[3],
            stepDeg: step, hours: hours,
            fields: try parseFields(root, hours: hours,
                                    bbox: bbox, step: step))
        return pack
    }

    private static func parseFields(_ root: [String: Any], hours: [Int],
                                    bbox: [Double], step: Double)
        throws -> [String: Field] {
        let nLat = Int(((bbox[2] - bbox[0]) / step).rounded()) + 1
        let nLon = Int(((bbox[3] - bbox[1]) / step).rounded()) + 1
        let expected = hours.count * nLat * nLon
        let raw = root["fields"] as? [String: [String: Any]] ?? [:]
        var out: [String: Field] = [:]
        for name in requiredFields {
            guard let f = raw[name],
                  let unit = f["unit"] as? String,
                  let scale = f["scale"] as? Double
                    ?? (f["scale"] as? Int).map(Double.init),
                  let values = f["values"] as? [Int] else {
                throw DecodeError.missingField(name)
            }
            guard values.count == expected else {
                throw DecodeError.sizeMismatch(name)
            }
            out[name] = Field(unit: unit, scale: scale, values: values)
        }
        return out
    }
}
