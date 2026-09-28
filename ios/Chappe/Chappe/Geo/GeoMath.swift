import Foundation

// ============================================================================
// Гео-математика слоя карты: расстояние и азимут по прямой.
//
// Формулы зафиксированы тест-векторами tests/geo_math_vectors.json
// (генератор sim/geo_math_vectors_gen.py) — Swift обязан сходиться с Python.
//
// Принцип проекта: числа считает код, модель только формулирует. Эти две
// функции — единственный источник расстояний и азимутов для UI и
// инструментов Софи.
// ============================================================================

nonisolated enum GeoMath {

    /// Средний радиус Земли, метры. Гаверсинус на сфере: ошибка против
    /// эллипсоида < 0.5 % — для «по прямой» в мессенджере достаточно,
    /// маршрутов и навигации в v1 нет.
    static let earthRadius = 6_371_000.0

    /// Скорость пешехода для оценок времени, м/с. Единственное место,
    /// где она задана: walk_eta Софи и подписи UI берут отсюда.
    static let walkingSpeed = 1.4

    /// Расстояние по прямой (гаверсинус), метры.
    static func distanceMeters(lat1: Double, lon1: Double,
                               lat2: Double, lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2)
              + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1.0, a.squareRoot()))
    }

    /// Прямая задача: точка на расстоянии `distanceMeters` по азимуту
    /// `bearingDegrees` от исходной (сфера). Нужна кругу неопределённости.
    static func destination(lat: Double, lon: Double,
                            bearingDegrees: Double,
                            distanceMeters: Double) -> (lat: Double, lon: Double) {
        let δ = distanceMeters / earthRadius
        let θ = bearingDegrees * .pi / 180
        let φ1 = lat * .pi / 180
        let λ1 = lon * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1),
                            cos(δ) - sin(φ1) * sin(φ2))
        var lonOut = λ2 * 180 / .pi
        if lonOut > 180 { lonOut -= 360 }
        if lonOut < -180 { lonOut += 360 }
        return (φ2 * 180 / .pi, lonOut)
    }

    /// Начальный азимут из точки 1 в точку 2: градусы 0..<360, 0 = север,
    /// по часовой стрелке.
    static func initialBearingDegrees(lat1: Double, lon1: Double,
                                      lat2: Double, lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}
