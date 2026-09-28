import Foundation

// ============================================================================
// Геохеш — механизм загрубления координат для .coarse-грантов (WP4).
//
// Грант с точностью .coarse(n) режет позицию до ячейки геохеша длины n
// (6 симв. ≈ 1.2 км, 5 ≈ 4.9 км, 4 ≈ 39 км) и отдаёт ЦЕНТР ячейки — именно
// он кодируется в эфир 6-байтовым PositionCodec. Восстановить точную
// позицию из байтов невозможно: загрубление происходит при кодировании,
// а не при отрисовке.
//
// Алгоритм — стандартный geohash (base32, чередование бит с долготы).
// Векторы: tests/geohash_vectors.json (генератор sim/geohash_vectors_gen.py).
// ============================================================================

nonisolated enum Geohash {

    static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Ячейка геохеша: строка и её границы.
    struct Cell: Equatable, Sendable {
        let hash: String
        let latRange: ClosedRange<Double>
        let lonRange: ClosedRange<Double>

        var centerLat: Double { (latRange.lowerBound + latRange.upperBound) / 2 }
        var centerLon: Double { (lonRange.lowerBound + lonRange.upperBound) / 2 }
    }

    /// Кодирует точку в ячейку длины `length` (1…12).
    static func cell(lat: Double, lon: Double, length: Int) -> Cell {
        precondition((1...12).contains(length), "длина геохеша 1…12")
        var latLo = -90.0, latHi = 90.0
        var lonLo = -180.0, lonHi = 180.0
        var chars: [Character] = []
        var bit = 0
        var ch = 0
        var even = true   // чётный бит — долгота
        while chars.count < length {
            if even {
                let mid = (lonLo + lonHi) / 2
                if lon >= mid { ch = (ch << 1) | 1; lonLo = mid }
                else { ch = ch << 1; lonHi = mid }
            } else {
                let mid = (latLo + latHi) / 2
                if lat >= mid { ch = (ch << 1) | 1; latLo = mid }
                else { ch = ch << 1; latHi = mid }
            }
            even.toggle()
            bit += 1
            if bit == 5 {
                chars.append(base32[ch])
                bit = 0
                ch = 0
            }
        }
        return Cell(hash: String(chars),
                    latRange: latLo...latHi,
                    lonRange: lonLo...lonHi)
    }

    /// Загрубление позиции: центр ячейки длины `length` + её полудиагональ
    /// как horizontalAccuracy. Именно этот фикс уходит в кодирование.
    static func coarsen(_ fix: PositionFix, toLength length: Int) -> PositionFix {
        let c = cell(lat: fix.lat, lon: fix.lon, length: length)
        // полудиагональ ячейки — честная оценка неопределённости загрубления
        let halfDiagonal = GeoMath.distanceMeters(
            lat1: c.latRange.lowerBound, lon1: c.lonRange.lowerBound,
            lat2: c.latRange.upperBound, lon2: c.lonRange.upperBound) / 2
        return PositionFix(lat: c.centerLat,
                           lon: c.centerLon,
                           horizontalAccuracy: max(fix.horizontalAccuracy, halfDiagonal),
                           timestamp: fix.timestamp,
                           source: fix.source,
                           precision: .coarse(geohashLength: length))
    }
}
