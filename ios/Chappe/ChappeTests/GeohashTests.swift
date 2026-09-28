//
//  GeohashTests.swift
//  RMTests
//
//  Геохеш — механизм .coarse-грантов: эталон tests/geohash_vectors.json
//  (sim/geohash_vectors_gen.py). Ключевая гарантия — coarsen() возвращает
//  центр ячейки, а не исходную точку.
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

private struct HashVectors: Decodable {
    struct Entry: Decodable {
        let name: String
        let lat: Double
        let lon: Double
        let hashes: [String: Item]
    }
    struct Item: Decodable {
        let geohash: String
        let cell_center_lat: Double
        let cell_center_lon: Double
    }
    let vectors: [Entry]
}

struct GeohashTests {

    @Test func matchesPythonReference() throws {
        let all = try JSONDecoder().decode(HashVectors.self,
                                           from: repoFile("tests/geohash_vectors.json"))
        for entry in all.vectors {
            for (lenStr, item) in entry.hashes {
                let cell = Geohash.cell(lat: entry.lat, lon: entry.lon,
                                        length: Int(lenStr)!)
                #expect(cell.hash == item.geohash, "\(entry.name)/\(lenStr)")
                #expect(abs(cell.centerLat - item.cell_center_lat) < 1e-12, "\(entry.name)")
                #expect(abs(cell.centerLon - item.cell_center_lon) < 1e-12, "\(entry.name)")
            }
        }
    }

    @Test func coarsenReplacesPointWithCellCenter() {
        let fix = PositionFix(lat: 33.5731, lon: -7.5898,
                              horizontalAccuracy: 10,
                              timestamp: Date(timeIntervalSince1970: 1_000_000),
                              source: .own, precision: .exact)
        let coarse = Geohash.coarsen(fix, toLength: 5)
        let cell = Geohash.cell(lat: fix.lat, lon: fix.lon, length: 5)
        #expect(coarse.lat == cell.centerLat)
        #expect(coarse.lon == cell.centerLon)
        #expect(coarse.precision == .coarse(geohashLength: 5))
        // неопределённость выросла до масштаба ячейки (~5 км уровень 5)
        #expect(coarse.horizontalAccuracy > 1_000)
        // время и источник не меняются: загрубление не «освежает» данные
        #expect(coarse.timestamp == fix.timestamp)
        #expect(coarse.source == fix.source)
    }

    @Test func coarseCellCenterDiffersFromExactPoint() {
        // Восстановить точность из загрублённых байтов невозможно:
        // в эфир уходит центр ячейки, не исходная точка.
        let fix = PositionFix(lat: 36.1408, lon: -5.3536,
                              horizontalAccuracy: 5,
                              timestamp: .init(timeIntervalSince1970: 0),
                              source: .own, precision: .exact)
        let coarse = Geohash.coarsen(fix, toLength: 4)
        let drift = GeoMath.distanceMeters(lat1: fix.lat, lon1: fix.lon,
                                           lat2: coarse.lat, lon2: coarse.lon)
        #expect(drift > 100, "центр ячейки 39-км уровня не совпадает с точкой")
    }
}
