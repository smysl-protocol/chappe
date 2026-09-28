import Foundation
import Testing
@testable import Chappe

// Замок на FieldSampler (починка виса карты 08.08: поле ищется один
// раз на картинку/тик, а не на каждый пиксель и частицу). Ожидания
// посчитаны вручную по определению билинейной интерполяции — не из
// проверяемого кода.
struct WeatherSamplerTests {

    /// Сетка 2×2, шаг 1°: узлы (0,0)=0, (0,1)=5, (1,0)=10, (1,1)=15
    /// (квантованные [0,10,20,30] × scale 0.5).
    private var pack: WeatherPack {
        WeatherPack(
            model: "test", runDate: Date(timeIntervalSince1970: 0),
            fetchedDate: Date(timeIntervalSince1970: 0),
            latMin: 0, lonMin: 0, latMax: 1, lonMax: 1, stepDeg: 1,
            hours: [0],
            fields: ["temp_2m": .init(unit: "C", scale: 0.5,
                                      values: [0, 10, 20, 30])])
    }

    @Test("билинейная интерполяция: центр ячейки — среднее узлов")
    func handComputedCenter() throws {
        let s = try #require(WeatherRender.FieldSampler(
            pack, field: "temp_2m", hourIdx: 0))
        // (0+5+10+15)/4 = 7.5 — посчитано вручную
        #expect(abs(s.sample(lat: 0.5, lon: 0.5) - 7.5) < 1e-9)
        // углы — ровно узлы
        #expect(abs(s.sample(lat: 0, lon: 0) - 0) < 1e-9)
        #expect(abs(s.sample(lat: 1, lon: 1) - 15) < 1e-9)
    }

    @Test("FieldSampler совпадает со старым путём sample()")
    func matchesLegacySample() throws {
        let s = try #require(WeatherRender.FieldSampler(
            pack, field: "temp_2m", hourIdx: 0))
        for (lat, lon) in [(0.25, 0.75), (0.9, 0.1), (-5.0, 7.0)] {
            let old = WeatherRender.sample(pack, field: "temp_2m",
                                           hourIdx: 0, lat: lat, lon: lon)
            #expect(abs(s.sample(lat: lat, lon: lon) - old) < 1e-9,
                    "расхождение в (\(lat), \(lon))")
        }
    }

    @Test("неизвестное поле — nil, не ноль молча")
    func unknownFieldIsNil() {
        #expect(WeatherRender.FieldSampler(pack, field: "нет-такого",
                                           hourIdx: 0) == nil)
    }
}
