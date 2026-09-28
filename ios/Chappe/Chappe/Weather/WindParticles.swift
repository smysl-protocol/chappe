import SwiftUI

// ============================================================================
// Анимация ветра частицами (хотелка №1, заказана владельцем 08.08 вместо
// статичных стрелок).
//
// Как устроено. Частицы живут в ГЕОГРАФИЧЕСКИХ координатах и плывут по
// тому же полю u/v, что рисовало стрелки (WeatherRender.sample —
// билинейная интерполяция пака). На экран они переводятся проекцией
// Меркатора по текущим видимым границам карты: это ровно то, чем
// проецирует сама карта, поэтому частицы не «съезжают» с местности при
// зуме и панорамировании.
//
// Почему не Metal-слой поверх карты: частицы рисуются обычным Canvas
// поверх карты — нет своего цикла отрисовки GPU, кадры идут только пока
// экран открыт и слой ветра включён. Расход держим низким сознательно:
// ~600 частиц, 24 кадра в секунду, тонкие линии со следом (см. Budget).
//
// Честная граница: частицы — это ПОКАЗ поля, а не симуляция погоды.
// Скорость и направление верны, но траектория частицы за минуты
// «настоящей» не является: поле берётся на один срок таймлайна и не
// меняется, пока человек не сдвинет ползунок.
// ============================================================================

/// Точка пути. Структура, не кортеж: кортежи в массиве гоняли
/// рантайм-метаданные и ARC на каждый кадр — это был заметный кусок
/// стека виса 08.08 (sample_zoom2: TupleCacheEntry, getGenericMetadata).
nonisolated struct GeoPoint: Equatable {
    var lat: Double
    var lon: Double
}

/// Одна частица: положение, предыдущее положение (для следа), возраст.
nonisolated struct WindParticle: Equatable {
    var lat: Double
    var lon: Double
    var prevLat: Double
    var prevLon: Double
    var age: Double        // секунды с рождения
    var life: Double       // сколько ей отмерено
    /// Хвост: последние точки пути. Без него частица — точка: за один
    /// кадр ветер сдвигает её меньше чем на пиксель (замер на мировом
    /// зуме 08.08), и движение читается только по мерцанию.
    var trail: [GeoPoint] = []

    static func == (a: WindParticle, b: WindParticle) -> Bool {
        a.lat == b.lat && a.lon == b.lon && a.age == b.age
    }
}

nonisolated enum WindField {

    /// Настройки расхода — держим скромно (батарея, решение владельца).
    enum Budget {
        static let particles = 600
        static let fps: Double = 24
        static let minLife: Double = 1.6
        static let maxLife: Double = 4.0
        /// Скорость ПОКАЗА в пикселях экрана в секунду при сильном
        /// ветре. Абсолютные м/с здесь не годятся: на мировом зуме
        /// 10 м/с — это доли пикселя за кадр, на городском — экран за
        /// мгновение. Глазу нужна одинаковая скорость, число читается
        /// со шкалы.
        static let maxPixelsPerSecond: Double = 55
        /// Ветер, при котором показ идёт на полной скорости.
        static let fastWind: Double = 18
        /// Длина хвоста в точках пути.
        static let trailPoints = 7
    }

    /// Родить частицу в случайной точке видимой области.
    static func spawn(in bbox: (latMin: Double, lonMin: Double,
                                latMax: Double, lonMax: Double),
                      random: (ClosedRange<Double>) -> Double) -> WindParticle {
        let lat = random(bbox.latMin...bbox.latMax)
        let lon = random(bbox.lonMin...bbox.lonMax)
        return WindParticle(lat: lat, lon: lon, prevLat: lat, prevLon: lon,
                            age: 0,
                            life: random(Budget.minLife...Budget.maxLife))
    }

    /// Шаг симуляции — ЧИСТАЯ функция (тестируется без экрана).
    ///
    /// Ветер задан компонентами u (на восток) и v (на север) в м/с.
    /// Перевод в градусы: по широте 1° ≈ 110.54 км, по долготе 1° ≈
    /// 111.32 км × cos(широты) — у полюсов долгота сжимается, иначе
    /// частицы там летели бы неправдоподобно быстро.
    /// `spanScale` — во сколько раз видимая область шире опорной (60°).
    /// Без него на мировом зуме частица за кадр смещается меньше пикселя
    /// и рой выглядит неподвижной крапой, а на городском — улетает за
    /// экран. Скорость движения по ЭКРАНУ так остаётся одинаковой.
    static func step(_ p: WindParticle, u: Double, v: Double,
                     dt: Double, degPerPixel: Double) -> WindParticle {
        var next = p
        next.prevLat = p.lat
        next.prevLon = p.lon
        next.trail.append(GeoPoint(lat: p.lat, lon: p.lon))
        if next.trail.count > Budget.trailPoints { next.trail.removeFirst() }

        let speed = (u * u + v * v).squareRoot()
        guard speed > 0.01 else { next.age += dt; return next }
        // доля от «сильного ветра» → доля от полной скорости показа
        let share = min(speed / Budget.fastWind, 1)
        let pixels = share * Budget.maxPixelsPerSecond * dt
        let degrees = pixels * degPerPixel
        let cosLat = max(cos(p.lat * .pi / 180), 0.15)   // защита у полюсов
        next.lat += (v / speed) * degrees
        next.lon += (u / speed) * degrees / cosLat
        next.age += dt
        return next
    }

    /// Опорная ширина области, к которой нормируем скорость на экране.
    static let referenceSpanDeg: Double = 60

    /// Пора ли перерождать: вышла за область, отжила своё или встала
    /// в мёртвый штиль (иначе точки копятся в «карманах» поля).
    static func needsRespawn(_ p: WindParticle,
                             in bbox: (latMin: Double, lonMin: Double,
                                       latMax: Double, lonMax: Double),
                             speed: Double) -> Bool {
        p.age >= p.life
            || p.lat < bbox.latMin || p.lat > bbox.latMax
            || p.lon < bbox.lonMin || p.lon > bbox.lonMax
            || speed < 0.2
    }

    /// Меркатор: широта → нормированная координата 0…1 сверху вниз.
    /// Та же проекция, что у карты, поэтому частицы держатся местности.
    static func mercatorY(_ lat: Double) -> Double {
        let clamped = min(max(lat, -85), 85) * .pi / 180
        return log(tan(.pi / 4 + clamped / 2))
    }

    /// Точка на экране для географических координат. Вырожденная
    /// область не рождает бесконечность: Path с inf/NaN — патология
    /// для CoreGraphics.
    static func screenPoint(lat: Double, lon: Double,
                            bbox: (latMin: Double, lonMin: Double,
                                   latMax: Double, lonMax: Double),
                            size: CGSize) -> CGPoint {
        let x = (lon - bbox.lonMin) / max(bbox.lonMax - bbox.lonMin, 1e-9)
        let yTop = mercatorY(bbox.latMax), yBottom = mercatorY(bbox.latMin)
        let y = (yTop - mercatorY(lat)) / max(yTop - yBottom, 1e-9)
        return CGPoint(x: x * size.width, y: y * size.height)
    }

    /// Пора ли считать следующий тик симуляции. nil — рано: кадры,
    /// приходящие чаще бюджета (120 Гц жеста, шторм перерисовок),
    /// НЕ двигают частицы и не трогают состояние — это разрывает
    /// петлю «перерисовка → тик → мутация → перерисовка», которая
    /// вешала главный поток намертво (вис 08.08, sample_zoom2).
    static func tickDT(now: Date, lastTick: Date?) -> Double? {
        guard let lastTick else { return 1.0 / Budget.fps }
        let dt = now.timeIntervalSince(lastTick)
        guard dt >= 1.0 / Budget.fps * 0.9 else { return nil }
        return min(dt, 0.2)
    }
}

/// Слой частиц поверх карты. Живёт, только пока включён ветер и экран
/// открыт: TimelineView останавливается вместе с экраном.
struct WindParticlesView: View {
    let pack: WeatherPack
    let hourIdx: Int
    let bbox: RegionBBox

    @State private var particles: [WindParticle] = []
    @State private var lastTick: Date?

    private var bounds: (latMin: Double, lonMin: Double,
                         latMax: Double, lonMax: Double) {
        (bbox.minLat, bbox.minLon, bbox.maxLat, bbox.maxLon)
    }

    /// Якорь расписания — СТАБИЛЬНЫЙ (@State, живёт с вьюхой).
    /// `.periodic(from: .now)` пересоздавал расписание при каждой
    /// пересборке body: свежий якорь давал немедленный «тик», тик
    /// мутировал частицы, мутация пересобирала body — главный поток
    /// зацикливался и не возвращался к событиям (вис 08.08: стек
    /// sample_zoom2 — 18+ с внутри одной CATransaction; кнопки и
    /// таб-бар мертвы даже после окончания жеста).
    @State private var scheduleAnchor = Date()

    var body: some View {
        TimelineView(.periodic(from: scheduleAnchor,
                               by: 1.0 / WindField.Budget.fps)) { timeline in
            Canvas { context, size in
                // пять корзин затухания вместо 600 отдельных штрихов:
                // один stroke на корзину (стоимость кадра — вторая
                // половина стека виса 08.08)
                var buckets = [Path](repeating: Path(), count: 5)
                for p in particles {
                    guard !p.trail.isEmpty else { continue }
                    var path = Path()
                    path.move(to: WindField.screenPoint(
                        lat: p.trail[0].lat, lon: p.trail[0].lon,
                        bbox: bounds, size: size))
                    for point in p.trail.dropFirst() {
                        path.addLine(to: WindField.screenPoint(
                            lat: point.lat, lon: point.lon,
                            bbox: bounds, size: size))
                    }
                    path.addLine(to: WindField.screenPoint(
                        lat: p.lat, lon: p.lon, bbox: bounds, size: size))
                    // след гаснет к концу жизни — рой не «моргает» разом
                    let fade = 1 - (p.age / max(p.life, 0.01))
                    let bucket = min(max(Int(fade * 5), 0), 4)
                    buckets[bucket].addPath(path)
                }
                for (i, path) in buckets.enumerated() where !path.isEmpty {
                    let fade = (Double(i) + 0.5) / 5
                    context.stroke(
                        path,
                        with: .color(.white.opacity(0.75 * max(fade, 0.2))),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
            }
            .onChange(of: timeline.date) { _, now in
                advance(to: now)
            }
        }
        .allowsHitTesting(false)     // карта под слоем остаётся живой
        // ширина канвы — снаружи, а не записью состояния из тела
        // отрисовки (запись из draw — ещё один повод перерисовки)
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.width
        } action: { width in
            canvasWidth = max(width, 1)
        }
        .onAppear { reseed() }
        // Смена области НЕ пересеивает рой (вис 08.08: пинч меняет
        // bbox на каждом кадре жеста, полный пересев 600 частиц ×
        // 60 кадров/с душил главный поток вместе с жестом). Частицы
        // географически привязаны: вышедшие за новую область
        // needsRespawn расселит по ней за ближайшие тики.
        .onChange(of: hourIdx) { _, _ in reseed() }
    }

    private func reseed() {
        lastTick = nil
        particles = (0..<WindField.Budget.particles).map { _ in
            WindField.spawn(in: bounds, random: { Double.random(in: $0) })
        }
    }

    /// Сколько градусов долготы приходится на пиксель экрана: через это
    /// скорость показа переводится из пикселей в градусы, и движение по
    /// экрану выглядит одинаково на любом зуме.
    @State private var canvasWidth: Double = 390
    private var degPerPixel: Double {
        (bounds.lonMax - bounds.lonMin) / max(canvasWidth, 1)
    }

    private func advance(to now: Date) {
        // кадры чаще бюджета (жест, шторм перерисовок) не двигают
        // частицы и не трогают состояние — иначе петля (см. body)
        guard let dt = WindField.tickDT(now: now, lastTick: lastTick) else {
            return
        }
        lastTick = now
        // сэмплеры полей — один раз за тик, не дважды на частицу
        // (вис 08.08: словарный поиск поля на каждый вызов)
        guard let uField = WeatherRender.FieldSampler(
                pack, field: "wind_u10", hourIdx: hourIdx),
              let vField = WeatherRender.FieldSampler(
                pack, field: "wind_v10", hourIdx: hourIdx) else { return }
        particles = particles.map { p in
            let u = uField.sample(lat: p.lat, lon: p.lon)
            let v = vField.sample(lat: p.lat, lon: p.lon)
            let moved = WindField.step(p, u: u, v: v, dt: dt,
                                       degPerPixel: degPerPixel)
            let speed = (u * u + v * v).squareRoot()
            if WindField.needsRespawn(moved, in: bounds, speed: speed) {
                return WindField.spawn(in: bounds,
                                       random: { Double.random(in: $0) })
            }
            return moved
        }
    }
}
