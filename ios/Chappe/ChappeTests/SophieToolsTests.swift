//
//  SophieToolsTests.swift
//  RMTests
//
//  Инструменты Софи (фаза 2а): гаверсинус на известных парах, выбор
//  инструмента через StructuredLLM на мок-провайдере (P2 планировщика),
//  ветка «разрешение отклонено», валидация аргументов.
//

import Foundation
import Testing
@testable import Chappe

/// Мок, отдающий заранее заданный текст (эмуляция ответа модели
/// на вызов выбора инструмента).
actor CannedProvider {
    nonisolated let kind: LLMProviderKind = .local
    nonisolated let capabilities: LLMCapabilities = [.cancellation]
    private(set) var isLoaded = false
    let canned: String

    init(canned: String) { self.canned = canned }

    func load(_ config: LLMModelConfig) async throws { isLoaded = true }
    func unload() async { isLoaded = false }
    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: canned, tokensGenerated: 1,
                    tokensPerSecond: 0, finishReason: .stop)
    }
    func generateStructured(_ request: LLMRequest,
                            spec: StructuredSpec) async throws -> LLMResponse {
        throw LLMError.structuredOutputUnsupported
    }
    nonisolated func cancelActiveGeneration() {}
}

struct SophieToolsTests {

    // MARK: Гаверсинус

    @Test func haversineKnownPairs() {
        // Один градус долготы на экваторе ≈ 111.19 км
        let equator = SophieTools.haversineKm(lat1: 0, lon1: 0, lat2: 0, lon2: 1)
        #expect(abs(equator - 111.19) < 0.5, "экватор: \(equator)")

        // Москва — Санкт-Петербург ≈ 634 км
        let mskSpb = SophieTools.haversineKm(lat1: 55.7558, lon1: 37.6173,
                                           lat2: 59.9343, lon2: 30.3351)
        #expect(abs(mskSpb - 634) < 5, "Мск-СПб: \(mskSpb)")

        // Нулевое расстояние
        #expect(SophieTools.haversineKm(lat1: 8.71, lon1: 115.17,
                                      lat2: 8.71, lon2: 115.17) < 0.001)
    }

    @Test func distanceSummaryUsesWalkingSpeed() {
        // 4.5 км при 4.5 км/ч = ровно час
        let summary = SophieTools.distanceSummary(km: 4.5)
        #expect(summary.contains("4.5 км"))
        #expect(summary.contains("1.0 ч"), "итог: \(summary)")
    }

    // MARK: Выбор инструмента через планировщик (P2) на моке

    private func choose(canned: String) async throws -> SophieToolCall {
        let scheduler = ModelScheduler(makeProvider: { CannedProvider(canned: canned) })
        let request = LLMRequest(prompt: SophieTools.selectionPrompt(for: "тест"),
                                 maxTokens: 80, samplingOverride: .extraction)
        return try await scheduler.withProvider(.interactive) { provider in
            try await StructuredLLM.call(provider: provider,
                                         request: request,
                                         spec: SophieTools.selectionSpec,
                                         as: SophieToolCall.self,
                                         validate: SophieTools.validate(_:))
        }
    }

    @Test func selectionParsesDeviceStatus() async throws {
        let call = try await choose(canned: #"{"tool": "device_status"}"#)
        #expect(call.tool == .deviceStatus)
    }

    @Test func selectionParsesDistanceWithArgs() async throws {
        let call = try await choose(
            canned: #"Вот JSON: {"tool": "distance_eta", "target_lat": 33.59, "target_lon": -7.61}"#)
        #expect(call.tool == .distanceEta)
        #expect(call.targetLat == 33.59)
        #expect(call.targetLon == -7.61)
    }

    @Test func selectionRejectsInventedTool() async throws {
        // Выдуманный инструмент не проходит Decodable-enum; repair на моке
        // возвращает тот же текст — итог invalidStructuredResult, чат
        // обязан отвалиться в обычный ответ (см. toolBlockIfNeeded)
        await #expect(throws: LLMError.self) {
            _ = try await self.choose(canned: #"{"tool": "call_helicopter"}"#)
        }
    }

    @Test func distanceWithoutTargetFailsValidation() async throws {
        await #expect(throws: LLMError.self) {
            _ = try await self.choose(canned: #"{"tool": "distance_eta"}"#)
        }
    }

    // MARK: Ветка «разрешение отклонено»

    @Test func deniedLocationExplainsSettingsPath() {
        let result = SophieTools.renderLocation(.denied)
        #expect(result.summary.contains("не разрешён"))
        #expect(result.summary.contains("Настройк"), "должен объяснить, где включить")
        #expect(result.coordsAgeSeconds == nil)
    }

    @Test func staleFixIsFlaggedForAnswer() {
        let result = SophieTools.renderLocation(
            .location(lat: 8.71, lon: 115.17, ageSeconds: 7200))
        #expect(result.summary.contains("давние"))
        let block = SophieTools.answerBlock(for: result)
        #expect(block.contains("возраст координат"),
                "вызов №2 обязан требовать назвать возраст")
    }
}

extension CannedProvider: LLMProvider {}
