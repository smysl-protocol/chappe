import Testing
import Foundation
@testable import Chappe

// Анимация ветра частицами (заказ владельца 08.08). Ожидания —
// из физики и из требования «движение по экрану одинаково на любом
// зуме», а не из кода.
struct WindParticlesTests {

    private let world = (latMin: -85.0, lonMin: -180.0,
                         latMax: 85.0, lonMax: 180.0)

    private func particle(lat: Double = 0, lon: Double = 0) -> WindParticle {
        WindParticle(lat: lat, lon: lon, prevLat: lat, prevLon: lon,
                     age: 0, life: 3)
    }

    // Телепорт карты (поиск, тап по контакту, вопрос владельца 08.08):
    // частицы обязаны оказаться на новом месте первым же тиком, без
    // «переползания через полмира». Механика: старая частица вне новой
    // области → needsRespawn; рождённая взамен — внутри области и с
    // ПУСТЫМ хвостом (след рисуется только по хвосту).
    @Test func teleportRespawnsInPlaceWithoutCrossWorldTrail() {
        let dubai = (latMin: 24.5, lonMin: 54.75,
                     latMax: 25.5, lonMax: 55.5)
        let sanFrancisco = particle(lat: 37.77, lon: -122.42)
        #expect(WindField.needsRespawn(sanFrancisco, in: dubai, speed: 5),
                "частица старой области обязана переродиться")
        let born = WindField.spawn(in: dubai, random: { Double.random(in: $0) })
        #expect(born.lat >= dubai.latMin && born.lat <= dubai.latMax)
        #expect(born.lon >= dubai.lonMin && born.lon <= dubai.lonMax)
        #expect(born.trail.isEmpty, Comment(rawValue:
                "новорождённая частица без хвоста — линии через полмира "
                + "неоткуда взяться"))
        #expect(born.lat == born.prevLat && born.lon == born.prevLon)
    }

    @Test func eastWindMovesParticleEast() {
        // u > 0 — ветер НА восток: долгота обязана расти
        let moved = WindField.step(particle(), u: 10, v: 0, dt: 1,
                                   degPerPixel: 0.1)
        #expect(moved.lon > 0)
        #expect(abs(moved.lat) < 1e-9, "чистый зональный ветер широту не трогает")
    }

    @Test func northWindMovesParticleNorth() {
        let moved = WindField.step(particle(), u: 0, v: 10, dt: 1,
                                   degPerPixel: 0.1)
        #expect(moved.lat > 0)
    }

    // Главное свойство: скорость задана В ПИКСЕЛЯХ. На мировом зуме
    // (градусов на пиксель больше) шаг в градусах обязан быть больше —
    // иначе рой стоит крапой, как было в первом заходе 08.08.
    @Test func screenSpeedIsZoomIndependent() {
        let city = WindField.step(particle(), u: 10, v: 0, dt: 1,
                                  degPerPixel: 0.001)
        let globe = WindField.step(particle(), u: 10, v: 0, dt: 1,
                                   degPerPixel: 0.9)
        let cityPixels = city.lon / 0.001
        let globePixels = globe.lon / 0.9
        #expect(abs(cityPixels - globePixels) < 0.01,
                "в пикселях скорость одна и та же")
    }

    @Test func strongWindIsCappedNotUnbounded() {
        let strong = WindField.step(particle(), u: 200, v: 0, dt: 1,
                                    degPerPixel: 0.1)
        let fast = WindField.step(particle(), u: 18, v: 0, dt: 1,
                                  degPerPixel: 0.1)
        #expect(abs(strong.lon - fast.lon) < 1e-9,
                "ураган не должен рвать экран: скорость показа ограничена")
    }

    @Test func particleRespawnsWhenLeavingAreaOrInCalm() {
        var p = particle(lat: 84.9, lon: 179.9)
        p.lat = 90
        #expect(WindField.needsRespawn(p, in: world, speed: 5))
        let alive = particle()
        #expect(WindField.needsRespawn(alive, in: world, speed: 5) == false)
        #expect(WindField.needsRespawn(alive, in: world, speed: 0.05),
                "штиль: частица не должна копиться в кармане поля")
    }

    // Вис 08.08 (стек sample_zoom2): кадры, приходящие чаще бюджета
    // 24 к/с (жест на 120 Гц, шторм перерисовок), обязаны пропускаться
    // БЕЗ мутации состояния — иначе «перерисовка → тик → мутация →
    // перерисовка» зацикливает главный поток, и кнопки мертвы.
    @Test func subBudgetFramesAreSkipped() {
        let t0 = Date(timeIntervalSince1970: 1000)
        // бюджет 24 к/с ≈ 41.7 мс; кадр через 8 мс (120 Гц) — рано
        #expect(WindField.tickDT(now: t0.addingTimeInterval(0.008),
                                 lastTick: t0) == nil)
        // кадр через 42 мс — пора, dt настоящий (допуск 1e-6: ulp
        // Double на датах эпохи ~1.2e-7 — 1e-9 был строже точности дат)
        let dt = WindField.tickDT(now: t0.addingTimeInterval(0.042),
                                  lastTick: t0)
        #expect(dt != nil && abs(dt! - 0.042) < 1e-6)
        // первый тик без истории — стандартный шаг бюджета
        #expect(WindField.tickDT(now: t0, lastTick: nil) == 1.0 / 24)
        // возврат из фона не даёт гигантского прыжка
        #expect(WindField.tickDT(now: t0.addingTimeInterval(60),
                                 lastTick: t0) == 0.2)
    }

    // Замок затухания (поручение владельца 09.08): залп M тиков
    // дисплей-линка за фиксированные T секунд даёт ограниченное число
    // перепланировок — потолок из бюджета (T / (0.9/24) + 1), и оно
    // НЕ растёт с плотностью залпа. Плюс модель петли: сразу после
    // каждого принятого тика прилетает «эхо» перерисовки — оно обязано
    // быть пропущено всегда, иначе перепланировки размножаются.
    @Test func burstOfDisplayTicksIsDamped() {
        let t0 = Date(timeIntervalSince1970: 0)
        func accepted(ticksPerSecond: Double, seconds: Double) -> Int {
            var lastTick: Date?
            var count = 0
            var t = 0.0
            while t < seconds {
                let now = t0.addingTimeInterval(t)
                if WindField.tickDT(now: now, lastTick: lastTick) != nil {
                    lastTick = now
                    count += 1
                    #expect(WindField.tickDT(
                        now: now.addingTimeInterval(0.001),
                        lastTick: lastTick) == nil, Comment(rawValue:
                        "эхо перерисовки сразу после мутации обязано "
                        + "пропускаться — это и есть разорванная петля"))
                }
                t += 1.0 / ticksPerSecond
            }
            return count
        }
        // потолок из бюджета: 24 к/с с допуском джиттера 10%
        let cap = Int(2.0 / (0.9 / 24)) + 1
        let at120 = accepted(ticksPerSecond: 120, seconds: 2)
        let at960 = accepted(ticksPerSecond: 960, seconds: 2)
        let at9600 = accepted(ticksPerSecond: 9600, seconds: 2)
        #expect(at120 <= cap && at960 <= cap && at9600 <= cap)
        #expect(at9600 <= at960 + 2 && at960 <= at120 + 8, Comment(rawValue:
                "плотнее залп — не больше перепланировок: рост с M "
                + "означал бы, что петля жива"))
        #expect(at120 >= 40, "дроссель не душит саму анимацию (24 к/с)")
    }

    @Test func trailKeepsRecentPointsOnly() {
        var p = particle()
        for _ in 0..<20 {
            p = WindField.step(p, u: 5, v: 5, dt: 0.04, degPerPixel: 0.5)
        }
        #expect(p.trail.count == WindField.Budget.trailPoints,
                "хвост ограничен, иначе память растёт бесконечно")
    }

    // Проекция: север сверху, центр области — в центре экрана.
    @Test func projectionPutsNorthUpAndCentreInCentre() {
        let size = CGSize(width: 400, height: 800)
        let bbox = (latMin: -10.0, lonMin: -10.0, latMax: 10.0, lonMax: 10.0)
        let centre = WindField.screenPoint(lat: 0, lon: 0, bbox: bbox,
                                           size: size)
        #expect(abs(centre.x - 200) < 0.5)
        #expect(abs(centre.y - 400) < 0.5)
        let north = WindField.screenPoint(lat: 9, lon: 0, bbox: bbox,
                                          size: size)
        #expect(north.y < centre.y, "север выше юга")
    }

    @Test func poleDoesNotProduceInfinity() {
        let p = WindField.step(particle(lat: 84.9), u: 10, v: 10, dt: 1,
                               degPerPixel: 0.5)
        #expect(p.lat.isFinite && p.lon.isFinite)
        #expect(WindField.mercatorY(90).isFinite, "полюс не рвёт проекцию")
    }
}
