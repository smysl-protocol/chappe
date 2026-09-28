//
//  MarkerRenderingTests.swift
//  RMTests
//
//  Метки видимо стареют (критерий приёмки №3): проверяется подкруткой
//  времени — цвет/прозрачность/круг меняются от возраста фикса.
//

import Foundation
import Testing
@testable import Chappe

private let t0 = Date(timeIntervalSince1970: 1_753_900_000)

private func peerMarker(ageSeconds: Double, accuracy: Double = 10) -> MapMarker {
    MapMarker(id: "p", kind: .peer(contactID: "c1", name: "Сергей"),
              fix: PositionFix(lat: 36.0, lon: -5.6,
                               horizontalAccuracy: accuracy,
                               timestamp: t0.addingTimeInterval(-ageSeconds),
                               source: .peer("c1"), precision: .exact))
}

struct MarkerRenderingTests {

    @Test func markersVisiblyAge() {
        // Одна и та же метка в разные моменты — разный вид
        let fresh = peerMarker(ageSeconds: 60)
        let old = peerMarker(ageSeconds: 2 * 3600)
        #expect(MarkerRendering.dotColor(for: fresh, now: t0)
                != MarkerRendering.dotColor(for: old, now: t0))
        #expect(MarkerRendering.opacity(for: old, now: t0)
                < MarkerRendering.opacity(for: fresh, now: t0))
    }

    @Test func ageLabelIsOnEveryMarker() {
        let marker = peerMarker(ageSeconds: 40 * 60)
        #expect(MarkerRendering.ageLabel(for: marker, now: t0) == "40 мин назад")
    }

    @Test func uncertaintyCircleGrowsWithAge() {
        let fresh = peerMarker(ageSeconds: 120)
        let old = peerMarker(ageSeconds: 1800)
        let freshRing = MarkerRendering.uncertaintyCircle(for: fresh, now: t0)
        let oldRing = MarkerRendering.uncertaintyCircle(for: old, now: t0)
        #expect(!freshRing.isEmpty && !oldRing.isEmpty)
        // радиус растёт: точки кольца дальше от центра
        let freshR = GeoMath.distanceMeters(lat1: 36.0, lon1: -5.6,
                                            lat2: freshRing[0].lat,
                                            lon2: freshRing[0].lon)
        let oldR = GeoMath.distanceMeters(lat1: 36.0, lon1: -5.6,
                                          lat2: oldRing[0].lat,
                                          lon2: oldRing[0].lon)
        #expect(oldR > freshR)
        // и сходится с формулой r(t) = acc + 1.4·Δt
        #expect(abs(oldR - (10 + 1800 * 1.4)) < 5)
    }

    @Test func tinyFreshCircleIsHidden() {
        // Свежая точная позиция — круг меньше порога не рисуется
        let marker = peerMarker(ageSeconds: 5, accuracy: 5)
        #expect(MarkerRendering.uncertaintyCircle(for: marker, now: t0).isEmpty)
    }

    @Test func sosAlwaysDominant() {
        let sos = MapMarker(id: "s", kind: .sos,
                            fix: PositionFix(lat: 0, lon: 0,
                                             horizontalAccuracy: 300,
                                             timestamp: t0.addingTimeInterval(-7 * 3600),
                                             source: .manual, precision: .exact))
        // SOS не скрывается даже архивным и всегда цвета danger
        #expect(MarkerRendering.isVisible(sos, now: t0, showArchived: false))
        #expect(MarkerRendering.dotColor(for: sos, now: t0) == RMDesign.danger)
    }
}
