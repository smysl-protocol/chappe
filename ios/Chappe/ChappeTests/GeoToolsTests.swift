//
//  GeoToolsTests.swift
//  RMTests
//
//  Гео-инструменты Софи (WP6): peer_position и tile_coverage. Принципы:
//  числа считает код; возраст данных обязателен; радио-тишина (инструмент
//  ничего не шлёт в эфир). Зависимости инжектируются — тесты герметичны.
//

import Foundation
import Testing
@testable import Chappe

private let t0 = Date()

private func contact(_ name: String, id: String) -> Contact {
    Contact(id: id, name: name, publicKeyBase64: "", addedAt: t0)
}

@MainActor
struct GeoToolsTests {

    private func call(_ tool: SophieTool, contactName: String? = nil,
                      lat: Double? = nil, lon: Double? = nil) throws -> SophieToolCall {
        var json: [String: Any] = ["tool": tool.rawValue]
        if let contactName { json["contact_name"] = contactName }
        if let lat { json["target_lat"] = lat }
        if let lon { json["target_lon"] = lon }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(SophieToolCall.self, from: data)
    }

    // MARK: Схема

    @Test func schemaListsNewTools() {
        // Правило №8: enum-значения перечислены и в схеме, и в промпте
        #expect(SophieTools.selectionSchemaJSON.contains("peer_position"))
        #expect(SophieTools.selectionSchemaJSON.contains("tile_coverage"))
        #expect(SophieTools.selectionPrompt(for: "x").contains("peer_position"))
        #expect(SophieTools.selectionPrompt(for: "x").contains("tile_coverage"))
    }

    @Test func schemaDecodesContactName() throws {
        let c = try call(.peerPosition, contactName: "Сергей")
        #expect(c.tool == .peerPosition)
        #expect(c.contactName == "Сергей")
    }

    // MARK: peer_position

    @Test func peerPositionWithoutContactsIsHonest() throws {
        let result = SophieTools.runPeerPosition(try call(.peerPosition),
                                               contacts: [],
                                               store: PeerPositionStore(persisted: false))
        #expect(result.summary.contains("контактов пока нет"))
        #expect(result.coordsAgeSeconds == nil)
    }

    @Test func peerPositionUnknownNameListsKnown() throws {
        let result = SophieTools.runPeerPosition(
            try call(.peerPosition, contactName: "Неизвестный"),
            contacts: [contact("Сергей", id: "c1")],
            store: PeerPositionStore(persisted: false))
        #expect(result.summary.contains("Сергей"))
    }

    @Test func peerPositionWithoutFixSuggestsAskingNotSending() throws {
        // Радио-тишина: нет позиции → предложение попросить, не запрос в эфир
        let result = SophieTools.runPeerPosition(
            try call(.peerPosition),
            contacts: [contact("Сергей", id: "c1")],
            store: PeerPositionStore(persisted: false))
        #expect(result.summary.contains("ещё не приходило"))
        #expect(result.summary.contains("ПРЕДЛОЖИТЬ"))
    }

    @Test func peerPositionAlwaysCarriesAge() throws {
        let store = PeerPositionStore(persisted: false)
        // позиция пришла 40 минут назад
        store.ingest(contactID: "c1", lat: 36.01, lon: -5.60,
                     receivedAt: Date().addingTimeInterval(-40 * 60))
        let result = SophieTools.runPeerPosition(
            try call(.peerPosition),
            contacts: [contact("Сергей", id: "c1")],
            store: store)
        // возраст — обязательное поле результата, «он в 3 км» без возраста запрещён
        #expect(result.coordsAgeSeconds != nil)
        #expect(abs((result.coordsAgeSeconds ?? 0) - 40 * 60) < 60)
        #expect(result.summary.contains("мин назад"))
        #expect(result.summary.contains("неопределённость"))
        #expect(result.involvesCoordinates)
    }

    @Test func peerPositionDistanceIsComputedByCode() throws {
        let store = PeerPositionStore(persisted: false)
        store.ingest(contactID: "c1", lat: 36.1408, lon: -5.3536,
                     receivedAt: Date())
        let own = PositionFix(lat: 36.01, lon: -5.60, horizontalAccuracy: 10,
                              timestamp: Date(), source: .own, precision: .exact)
        let result = SophieTools.runPeerPosition(
            try call(.peerPosition),
            contacts: [contact("Сергей", id: "c1")],
            store: store, ownFix: own)
        // расстояние и азимут посчитаны кодом и присутствуют в данных
        #expect(result.summary.contains("от нас"))
        #expect(result.summary.contains("азимут"))
        #expect(result.summary.contains("по прямой"))
    }

    @Test func peerPositionManyContactsAsksWhich() throws {
        let result = SophieTools.runPeerPosition(
            try call(.peerPosition),
            contacts: [contact("Сергей", id: "c1"), contact("Анна", id: "c2")],
            store: PeerPositionStore(persisted: false))
        #expect(result.summary.contains("чья"))
    }

    // MARK: tile_coverage

    private var gibraltarCoverage: CoverageIndex {
        CoverageIndex(regions: [
            MapRegion(id: "gib", name: "Гибралтар", bbox:
                        RegionBBox(minLat: 35.85, minLon: -5.90,
                                   maxLat: 36.30, maxLon: -5.30),
                      minZoom: 0, maxZoom: 14, sizeBytes: nil,
                      downloadedAt: nil, styleVersion: nil, state: .ready),
        ])
    }

    @Test func tileCoverageFindsRegionByPoint() async throws {
        let result = await SophieTools.runTileCoverage(
            try call(.tileCoverage, lat: 36.01, lon: -5.60),
            coverage: gibraltarCoverage, readyRegionNames: ["Гибралтар"])
        #expect(result.summary.contains("есть"))
        #expect(result.summary.contains("Гибралтар"))
    }

    @Test func tileCoverageIsHonestAboutGaps() async throws {
        let result = await SophieTools.runTileCoverage(
            try call(.tileCoverage, lat: 33.57, lon: -7.59),   // Касабланка
            coverage: gibraltarCoverage, readyRegionNames: ["Гибралтар"])
        #expect(result.summary.contains("НЕТ"))
        // и объясняет физику: по мешу тайлы не приедут
        #expect(result.summary.contains("по мешу"))
    }

    // MARK: Азимут

    @Test func compassPointsAreCorrect() {
        #expect(SophieTools.compassPoint(0) == "север")
        #expect(SophieTools.compassPoint(45) == "северо-восток")
        #expect(SophieTools.compassPoint(90) == "восток")
        #expect(SophieTools.compassPoint(180) == "юг")
        #expect(SophieTools.compassPoint(270) == "запад")
        #expect(SophieTools.compassPoint(359) == "север")
    }
}
