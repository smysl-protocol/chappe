import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Инструмент weather (полевой запрос владельца 22.08: «Софи говорит,
// что ничего не знает о погоде, хотя мы грузим погоду»). Спека Софи §2:
// погода — четвёртый источник фактов, ДЕТЕРМИНИРОВАННО из скачанного
// пака; возраст прогноза обязателен (контракт пака: от runDate).
// Фикстура — WeatherStore.makeStubPack (DEBUG), сеть не трогается.
// ============================================================================

@MainActor
struct SophieWeatherToolTests {

    @Test("прогноз рендерится из пака: значения, единицы и возраст")
    func stubPackRendersForecast() throws {
        let pack = try #require(WeatherStore.makeStubPack())
        let result = SophieTools.renderWeather(
            pack: pack, worldPack: nil, lat: 0, lon: 0,
            label: "Убуд (Индонезия)", now: pack.runDate)

        #expect(result.summary.contains("°C"),
                "температура с единицей обязана быть в ответе")
        #expect(result.summary.contains("ветер"),
                "ветер — второй обязательный слой")
        #expect(result.summary.contains("прогон"), Comment(rawValue:
                "возраст прогноза ОБЯЗАН звучать (контракт пака: прогноз "
                + "без возраста врёт — как координаты без времени)"))
        #expect(result.summary.contains("Убуд"),
                "место названо, география не выдумывается")
    }

    @Test("точка вне пака — честный отказ, не экстраполяция краёв")
    func outsideBBoxRefusesHonestly() throws {
        let pack = try #require(WeatherStore.makeStubPack())   // bbox ±65°
        let result = SophieTools.renderWeather(
            pack: pack, worldPack: nil, lat: 80, lon: 0,
            label: nil, now: pack.runDate)
        #expect(result.summary.contains("не скачан"), Comment(rawValue:
                "сэмплер молча зажимает края сетки — без гейта bbox Софи "
                + "рассказала бы «погоду» за пределами пака"))
        #expect(!result.summary.contains("°C"))
    }

    @Test("без пака вовсе — честный отказ с дорогой к скачиванию")
    func noPackRefusesWithHint() {
        let result = SophieTools.renderWeather(
            pack: nil, worldPack: nil, lat: 0, lon: 0,
            label: nil, now: Date())
        #expect(result.summary.contains("не скачан"))
        #expect(result.summary.contains("карт"),
                "подсказка, где скачивается погода (экран карты)")
    }
}
