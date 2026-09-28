//
//  TileStoreTests.swift
//  RMTests
//
//  Чистая часть WP2: слиппи-математика тайлов (оценка веса до
//  скачивания), bbox, индекс покрытия. Эталонные числа посчитаны
//  независимой Python-реализацией (см. REPORT_map_night.md).
//

import Foundation
import Testing
@testable import Chappe

/// Гибралтарский пролив, ~50×50 км — регион из брифа WP1.
private let gibraltar = RegionBBox(minLat: 35.85, minLon: -5.90,
                                   maxLat: 36.30, maxLon: -5.30)

struct TileMathTests {

    @Test func knownTileNumbers() {
        // Мировой тайл: на z0 всё в одном тайле
        #expect(TileMath.tileX(lon: 0, zoom: 0) == 0)
        #expect(TileMath.tileY(lat: 0, zoom: 0) == 0)
        // z1: точка (0,0) — юго-восточный квадрант (x1, y1)
        #expect(TileMath.tileX(lon: 0, zoom: 1) == 1)
        #expect(TileMath.tileY(lat: 0, zoom: 1) == 1)
        // Гибралтар z14 — сверено с независимой реализацией
        #expect(TileMath.tileX(lon: -5.90, zoom: 14) == 7923)
        #expect(TileMath.tileX(lon: -5.30, zoom: 14) == 7950)
        #expect(TileMath.tileY(lat: 36.30, zoom: 14) == 6416)
        #expect(TileMath.tileY(lat: 35.85, zoom: 14) == 6442)
    }

    @Test func gibraltarRegionCounts() {
        // 50×50 км: z14 — 756 тайлов, суммы z0–14 и z0–12
        #expect(TileMath.tileCount(bbox: gibraltar, zoom: 14) == 756)
        #expect(TileMath.tileCount(bbox: gibraltar, minZoom: 0, maxZoom: 14) == 1058)
        #expect(TileMath.tileCount(bbox: gibraltar, minZoom: 0, maxZoom: 12) == 92)
    }

    @Test func polesAreClamped() {
        // Web Mercator обрезается на ±85.05° — номера не выходят за сетку
        #expect(TileMath.tileY(lat: 90, zoom: 5) == 0)
        #expect(TileMath.tileY(lat: -90, zoom: 5) == 31)
    }

    @Test func emptyZoomRangeIsZero() {
        #expect(TileMath.tileCount(bbox: gibraltar, minZoom: 5, maxZoom: 4) == 0)
    }
}

struct CoverageIndexTests {

    private func region(_ id: String, _ bbox: RegionBBox,
                        state: RegionState) -> MapRegion {
        MapRegion(id: id, name: "Регион \(id)", bbox: bbox,
                  minZoom: 0, maxZoom: 14, sizeBytes: nil,
                  downloadedAt: nil, styleVersion: nil, state: state)
    }

    @Test func readyRegionCoversItsPoints() {
        let index = CoverageIndex(regions: [
            region("gib", gibraltar, state: .ready),
        ])
        // Тарифа — внутри пролива
        #expect(index.isCovered(lat: 36.01, lon: -5.60))
        #expect(index.regionName(lat: 36.01, lon: -5.60) == "Регион gib")
        // Касабланка — за границей покрытия: серая зона, не пустота
        #expect(!index.isCovered(lat: 33.57, lon: -7.59))
        #expect(index.regionName(lat: 33.57, lon: -7.59) == nil)
    }

    @Test func downloadingRegionDoesNotCover() {
        // Пока регион качается, честно говорим «тайлов нет»
        let index = CoverageIndex(regions: [
            region("gib", gibraltar, state: .downloading(progress: 0.7)),
        ])
        #expect(!index.isCovered(lat: 36.01, lon: -5.60))
    }

    @Test func staleRegionStillCovers() {
        // Устаревший стиль — тайлы всё ещё есть, карта работает
        let index = CoverageIndex(regions: [
            region("gib", gibraltar, state: .stale),
        ])
        #expect(index.isCovered(lat: 36.01, lon: -5.60))
    }

    @Test func bboxContainmentEdges() {
        #expect(gibraltar.contains(lat: 35.85, lon: -5.90))   // угол включён
        #expect(gibraltar.contains(lat: 36.30, lon: -5.30))
        #expect(!gibraltar.contains(lat: 36.31, lon: -5.60))
    }
}
