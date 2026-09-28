import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Контракт погодного пака (docs/weather_pack.md, решения владельца 06.08):
// пак без времени прогона не принимается ВООБЩЕ; возраст — от прогона,
// не от закачки. Ожидания посчитаны руками, не выведены из кода.
// ============================================================================

nonisolated struct WeatherPackTests {

    // Сетка 2×2 (bbox 10..10.25 / 105..105.25, шаг 0.25), два срока →
    // на поле ровно 2 × 2 × 2 = 8 значений. Посчитано руками.
    private func packJSON(mutate: (inout [String: Any]) -> Void = { _ in })
        -> Data {
        let eight = Array(repeating: 1, count: 8)
        var root: [String: Any] = [
            "format": "chappe.weather.pack",
            "version": 1,
            "model": "gfs-0p25",
            "run_unix": 1_754_625_600,      // 08.08.2026 04:00 UTC, руками
            "fetched_unix": 1_754_640_000,  // на 4 часа позже прогона
            "bbox": [10.0, 105.0, 10.25, 105.25],
            "step_deg": 0.25,
            "hours": [0, 3],
            "fields": [
                "wind_u10": ["unit": "m/s", "scale": 0.1, "values": eight],
                "wind_v10": ["unit": "m/s", "scale": 0.1, "values": eight],
                "temp_2m": ["unit": "C", "scale": 0.1, "values": eight],
                "cloud_total": ["unit": "%", "scale": 1, "values": eight],
                "precip": ["unit": "mm/h", "scale": 0.1, "values": eight],
            ],
        ]
        mutate(&root)
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private let now = Date(timeIntervalSince1970: 1_754_650_800) // руками

    @Test("правильный пак разбирается: сетка 2×2, два срока")
    func validPackDecodes() throws {
        let pack = try WeatherPack.decode(packJSON(), now: now)
        #expect(pack.gridLatCount == 2)
        #expect(pack.gridLonCount == 2)
        #expect(pack.hours == [0, 3])
        #expect(pack.fields.count == 5)
        #expect(pack.model == "gfs-0p25")
    }

    @Test("КОНТРАКТ: пак без времени прогона отклоняется целиком")
    func packWithoutRunTimeIsRejected() {
        let data = packJSON { $0.removeValue(forKey: "run_unix") }
        #expect(throws: WeatherPack.DecodeError.missingRunTime) {
            try WeatherPack.decode(data, now: now)
        }
    }

    @Test("КОНТРАКТ: возраст считается от прогона, не от закачки")
    func ageComesFromRunNotFetch() throws {
        let pack = try WeatherPack.decode(packJSON(), now: now)
        // now − run = 1 754 650 800 − 1 754 625 600 = 25 200 с = ровно 7 ч
        // (руками); от закачки было бы 3 ч — тест ловит подмену.
        #expect(pack.ageHours(now: now) == 7.0)
        #expect(pack.ageHours(now: now)
                != now.timeIntervalSince(pack.fetchedDate) / 3600)
    }

    @Test("прогон из будущего или до 2020 — отклоняется")
    func implausibleRunRejected() {
        let future = packJSON { $0["run_unix"] = 1_754_650_800 + 7200 }
        #expect(throws: WeatherPack.DecodeError.implausibleRunTime) {
            try WeatherPack.decode(future, now: now)
        }
        let ancient = packJSON {
            $0["run_unix"] = 1_500_000_000
            $0["fetched_unix"] = 1_500_000_100
        }
        #expect(throws: WeatherPack.DecodeError.implausibleRunTime) {
            try WeatherPack.decode(ancient, now: now)
        }
    }

    @Test("закачано раньше прогона — отклоняется")
    func fetchedBeforeRunRejected() {
        let data = packJSON { $0["fetched_unix"] = 1_754_625_599 }
        #expect(throws: WeatherPack.DecodeError.fetchedBeforeRun) {
            try WeatherPack.decode(data, now: now)
        }
    }

    @Test("длина поля не сходится с сеткой — отклоняется")
    func sizeMismatchRejected() {
        let data = packJSON { root in
            var fields = root["fields"] as! [String: [String: Any]]
            fields["precip"]?["values"] = Array(repeating: 1, count: 7)
            root["fields"] = fields
        }
        #expect(throws: WeatherPack.DecodeError.sizeMismatch("precip")) {
            try WeatherPack.decode(data, now: now)
        }
    }

    @Test("нет обязательного слоя — отклоняется")
    func missingFieldRejected() {
        let data = packJSON { root in
            var fields = root["fields"] as! [String: [String: Any]]
            fields.removeValue(forKey: "cloud_total")
            root["fields"] = fields
        }
        #expect(throws: WeatherPack.DecodeError.missingField("cloud_total")) {
            try WeatherPack.decode(data, now: now)
        }
    }

    @Test("чужой формат — отклоняется, а не разбирается частично")
    func foreignFormatRejected() {
        // Ответ Open-Meteo НЕ является паком: граница формата — здесь.
        let openMeteoLike = try! JSONSerialization.data(withJSONObject: [
            "latitude": 10.0, "longitude": 105.0,
            "hourly": ["temperature_2m": [30.1, 30.4]],
        ])
        #expect(throws: WeatherPack.DecodeError.notAPack) {
            try WeatherPack.decode(openMeteoLike, now: now)
        }
    }
}
