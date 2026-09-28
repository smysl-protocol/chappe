//
//  RegionGazetteerTests.swift
//  RMTests
//
//  Ф2 (бриф 31.07): офлайн-газеттир регионов — автодополнение с bbox,
//  имя по центру области, пересечение паков, потолок размера.
//

import Foundation
import Testing
@testable import Chappe

struct RegionGazetteerTests {

    /// «Мос» → Москва-город первым (крупнейшее население), Московская
    /// область — в списке. Ровно сценарий брифа.
    @Test func mosPrefixFindsMoscowCityAndOblast() {
        let hits = RegionGazetteer.shared.search("Мос")
        #expect(!hits.isEmpty)
        #expect(hits.first?.name == "Москва")
        #expect(hits.first?.isArea == false)
        #expect(hits.contains { $0.name == "Московская область" })
        // у каждого — рабочий bbox: вес считается локально
        for hit in hits {
            #expect(hit.bbox.maxLat > hit.bbox.minLat)
            #expect(hit.bbox.maxLon > hit.bbox.minLon)
        }
    }

    /// Латиница равноправна: Casablanca находится, страны русские.
    @Test func latinPrefixWorks() {
        let hits = RegionGazetteer.shared.search("Casabl")
        #expect(hits.contains { $0.country == "Марокко" })
    }

    /// Короткий запрос не сыплет весь мир.
    @Test func tooShortQueryGivesNothing() {
        #expect(RegionGazetteer.shared.search("М").isEmpty)
        #expect(RegionGazetteer.shared.search(" ").isEmpty)
    }

    /// Ф2.5: имя по точке — центр Москвы даёт «Москва».
    @Test func nameAtPointPrefersBiggestCity() {
        let name = RegionGazetteer.shared.name(atLat: 55.75, lon: 37.62)
        #expect(name == "Москва")
    }

    /// Точка вне всех bbox (высокая Арктика) честно не называется.
    /// Океан у экватора для этого не годится: bbox островных государств
    /// (Кирибати) накрывает огромные водные пространства — это честная
    /// цена прямоугольников.
    @Test func nameOutsideAllBBoxesIsNil() {
        #expect(RegionGazetteer.shared.name(atLat: 87, lon: 0) == nil)
    }
}

struct RegionOverlapTests {

    private func bbox(_ minLat: Double, _ minLon: Double,
                      _ maxLat: Double, _ maxLon: Double) -> RegionBBox {
        RegionBBox(minLat: minLat, minLon: minLon,
                   maxLat: maxLat, maxLon: maxLon)
    }

    /// Совпадение с самим собой — 100%, непересекающиеся — 0.
    @Test func overlapExtremes() {
        let a = bbox(0, 0, 10, 10)
        #expect(a.overlapRatio(with: a) == 1.0)
        #expect(a.overlapRatio(with: bbox(20, 20, 30, 30)) == 0)
    }

    /// Маленький пак целиком внутри большого — 100% относительно
    /// МЕНЬШЕГО: «Casablanca» и «Касабланка» ловятся, даже если рамки
    /// не совпали пиксель в пиксель.
    @Test func containedPackIsFullOverlap() {
        let big = bbox(0, 0, 10, 10)
        let small = bbox(2, 2, 4, 4)
        #expect(small.overlapRatio(with: big) == 1.0)
        #expect(big.overlapRatio(with: small) == 1.0)
    }

    /// Половинное пересечение — ровно на пороге предупреждения.
    @Test func halfOverlapAtThreshold() {
        let a = bbox(0, 0, 10, 10)
        let shifted = bbox(0, 5, 10, 15)
        #expect(abs(a.overlapRatio(with: shifted) - 0.5) < 0.001)
    }

    /// Потолок пака: дефолт 500 МБ, порог предупреждения ниже потолка.
    @Test func packCeilingDefaults() {
        #expect(MapConfig.maxPackBytes == 500_000_000)
        #expect(MapConfig.warnPackBytes < MapConfig.maxPackBytes)
    }
}
