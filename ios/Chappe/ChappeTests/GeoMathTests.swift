//
//  GeoMathTests.swift
//  RMTests
//
//  Гео-математика на известных парах координат: эталон —
//  tests/geo_math_vectors.json (sim/geo_math_vectors_gen.py).
//  Допуски: расстояние ±0.5 м или ±1e-6 относительная, азимут ±0.01°.
//

import Foundation
import Testing
@testable import Chappe

private func repoFile(_ relative: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent(relative))
}

private struct GeoVectors: Decodable {
    struct Point: Decodable { let lat: Double; let lon: Double }
    struct Vector: Decodable {
        let name: String
        let from: Point
        let to: Point
        let distance_m: Double
        let bearing_deg: Double
    }
    let vectors: [Vector]
}

struct GeoMathTests {

    @Test func distanceMatchesReference() throws {
        let all = try JSONDecoder().decode(GeoVectors.self,
                                           from: repoFile("tests/geo_math_vectors.json"))
        for v in all.vectors {
            let d = GeoMath.distanceMeters(lat1: v.from.lat, lon1: v.from.lon,
                                           lat2: v.to.lat, lon2: v.to.lon)
            let tolerance = max(0.5, v.distance_m * 1e-6)
            #expect(abs(d - v.distance_m) <= tolerance,
                    "\(v.name): \(d) != \(v.distance_m)")
        }
    }

    @Test func bearingMatchesReference() throws {
        let all = try JSONDecoder().decode(GeoVectors.self,
                                           from: repoFile("tests/geo_math_vectors.json"))
        for v in all.vectors where v.distance_m > 0 {
            let b = GeoMath.initialBearingDegrees(lat1: v.from.lat, lon1: v.from.lon,
                                                  lat2: v.to.lat, lon2: v.to.lon)
            #expect(abs(b - v.bearing_deg) <= 0.01,
                    "\(v.name): \(b) != \(v.bearing_deg)")
        }
    }

    @Test func bearingRangeIsNormalized() {
        // Запад: азимут 270, не -90.
        let b = GeoMath.initialBearingDegrees(lat1: 0, lon1: 0, lat2: 0, lon2: -1)
        #expect(abs(b - 270) < 0.01)
    }
}
