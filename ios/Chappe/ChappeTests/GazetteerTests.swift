//
//  GazetteerTests.swift
//  RMTests
//
//  Офлайн-газетир: ближайший пункт к известной точке, честная точка
//  в океане, румбы, правило формулировки, скорость <50 мс, поиск по
//  имени (включая неоднозначность) и интеграция с distance_eta.
//

import Foundation
import Testing
@testable import Chappe

struct GazetteerTests {

    /// Тест-точка у Касабланки: ближайший пункт — Марокко, единицы км.
    @Test func casablancaAreaPoint() {
        let hit = GazetteerStore.shared.nearest(lat: 33.51081, lon: -7.63242)
        let got = try? #require(hit)
        #expect(got?.country == "Марокко", "получено: \(String(describing: got))")
        #expect((got?.distanceKm ?? 999) < 15, "расстояние: \(got?.distanceKm ?? -1)")
        let phrase = GazetteerStore.phrase(for: got!)
        #expect(phrase.contains("км к") || phrase.contains("в районе"),
                "формулировка: \(phrase)")
    }

    /// Точка в Атлантике: далеко от всего, честная формулировка.
    @Test func oceanPointIsHonest() {
        let hit = GazetteerStore.shared.nearest(lat: 0, lon: -30)
        let got = try? #require(hit)
        #expect((got?.distanceKm ?? 0) > 300, "океан: \(got?.distanceKm ?? -1) км")
        let phrase = GazetteerStore.phrase(for: got!)
        #expect(phrase.contains("далеко от населённых пунктов"),
                "формулировка: \(phrase)")
    }

    /// Румбы: восемь направлений, границы секторов.
    @Test func rumbSectors() {
        #expect(GazetteerStore.rumb(0) == "северу")
        #expect(GazetteerStore.rumb(45) == "северо-востоку")
        #expect(GazetteerStore.rumb(90) == "востоку")
        #expect(GazetteerStore.rumb(135) == "юго-востоку")
        #expect(GazetteerStore.rumb(180) == "югу")
        #expect(GazetteerStore.rumb(225) == "юго-западу")
        #expect(GazetteerStore.rumb(270) == "западу")
        #expect(GazetteerStore.rumb(315) == "северо-западу")
        #expect(GazetteerStore.rumb(359) == "северу")
    }

    /// Правило формулировки: <3 км — «в районе».
    @Test func nearPhraseRule() {
        let near = GazetteerHit(name: "Тест", country: "Страна",
                                lat: 0, lon: 0, population: 1,
                                distanceKm: 1.2, bearingDeg: 90)
        #expect(GazetteerStore.phrase(for: near) == "в районе Тест, Страна")
        let mid = GazetteerHit(name: "Тест", country: "Страна",
                               lat: 0, lon: 0, population: 1,
                               distanceKm: 7.4, bearingDeg: 225)
        #expect(GazetteerStore.phrase(for: mid) == "7 км к юго-западу от Тест, Страна")
    }

    /// Скорость линейного перебора: <50 мс на ~235 тыс. записей
    /// (после прогрева — загрузка не в счёт).
    /// Контейнер (баг полевого теста): южная окраина Касабланки — точка
    /// ВНУТРИ мегаполиса (радиус по населению), не «7 км от Bouskoura».
    @Test func containerBeatsNearestSmallTown() {
        let context = GazetteerStore.shared.locate(lat: 33.51081, lon: -7.63242)
        #expect(context.container?.name == "Казабланка",
                "контейнер: \(String(describing: context.container))")
        let phrase = GazetteerStore.phrase(for: context)
        #expect(phrase.contains("части Казабланка"), "фраза: \(phrase)")
        #expect(phrase.contains("южн"), "точка на юге города: \(phrase)")
        #expect(phrase.contains("рядом Bouskoura"),
                "малый пункт ближе 8 км: \(phrase)")
        #expect(context.candidates.count == 5)
    }

    /// Радиус по населению: 0.01·√pop с клампом [2, 30].
    @Test func radiusFormula() {
        #expect(GazetteerStore.radiusKm(population: 100) == 2, "кламп снизу")
        #expect(abs(GazetteerStore.radiusKm(population: 1_000_000) - 10) < 0.01)
        #expect(GazetteerStore.radiusKm(population: 100_000_000) == 30, "кламп сверху")
    }

    /// Сельская точка вне всех радиусов — прежний формат «N км к румбу».
    @Test func ruralPointKeepsOldFormat() {
        // степь в Монголии
        let context = GazetteerStore.shared.locate(lat: 46.5, lon: 105.0)
        #expect(context.container == nil,
                "контейнер: \(String(describing: context.container))")
        let phrase = GazetteerStore.phrase(for: context)
        #expect(!phrase.contains("части"), "фраза: \(phrase)")
        #expect(phrase.contains("км к") || phrase.contains("далеко"),
                "фраза: \(phrase)")
    }

    /// Спор о месте: промпт выбора велит проверять вариант человека
    /// через distance_eta по имени; canned-ответ мока парсится в вызов.
    @Test func placeDisputeRoutesToDistanceByName() async throws {
        #expect(SophieTools.selectionPrompt(for: "x").contains("спорит"),
                "правило спора должно быть в промпте выбора")
        let scheduler = ModelScheduler(makeProvider: {
            CannedProvider(canned: #"{"tool": "distance_eta", "target_name": "Касабланка"}"#)
        })
        let request = LLMRequest(prompt: SophieTools.selectionPrompt(
            for: "мне кажется мы в Касабланке"), maxTokens: 80,
            samplingOverride: .extraction)
        let call = try await scheduler.withProvider(.interactive) { provider in
            try await StructuredLLM.call(provider: provider, request: request,
                                         spec: SophieTools.selectionSpec,
                                         as: SophieToolCall.self,
                                         validate: SophieTools.validate(_:))
        }
        #expect(call.tool == .distanceEta)
        #expect(call.targetName == "Касабланка")
    }

    /// Поиск по имени: Bouskoura — один пункт (Марокко).
    @Test func findByNameSingle() {
        let hits = GazetteerStore.shared.find(name: "bouskoura")
        #expect(hits.count == 1, "найдено: \(hits.map(\.name))")
        #expect(hits.first?.country == "Марокко")
    }

    /// Неоднозначное имя: Casablanca встречается в нескольких странах —
    /// инструмент просит уточнить.
    @Test func ambiguousNameAsksToClarify() async {
        let hits = GazetteerStore.shared.find(name: "casablanca")
        #expect(hits.count > 1, "ожидалась неоднозначность: \(hits.map(\.country))")

        let call = SophieToolCall(tool: .distanceEta, targetLat: nil,
                                targetLon: nil, fromLat: 1, fromLon: 1,
                                targetName: "Casablanca")
        let result = await SophieTools.runDistanceEta(call)
        #expect(result.summary.contains("несколько"))
        #expect(result.summary.contains("который"),
                "итог: \(result.summary)")
    }

    /// distance_eta по имени с заданной отправной точкой: считает код.
    @Test func distanceByNameWorks() async {
        let call = SophieToolCall(tool: .distanceEta, targetLat: nil,
                                targetLon: nil,
                                fromLat: 33.51081, fromLon: -7.63242,
                                targetName: "Bouskoura")
        let result = await SophieTools.runDistanceEta(call)
        #expect(result.summary.contains("Bouskoura (Марокко)"))
        #expect(result.summary.contains("км"), "итог: \(result.summary)")
        #expect(result.involvesCoordinates)
    }

    /// Допуск в одну букву: «Касабланка» находит «Казабланка» (Марокко)
    /// с пометкой corrected; тарабарщина не находит ничего.
    @Test func fuzzyOneLetterFindsTransliterationVariant() {
        let (hits, corrected) = GazetteerStore.shared.findFuzzy(name: "Касабланка")
        #expect(corrected, "имя должно быть помечено как поправленное")
        #expect(hits.contains { $0.name == "Казабланка" && $0.country == "Марокко" },
                "найдено: \(hits.map(\.name))")

        let (none, _) = GazetteerStore.shared.findFuzzy(name: "Кзсблнка")
        #expect(none.isEmpty, "две и более правки не допускаются: \(none.map(\.name))")

        // точное имя corrected не ставит
        let (exact, exactCorrected) = GazetteerStore.shared.findFuzzy(name: "bouskoura")
        #expect(!exactCorrected && exact.count == 1)
    }

    /// Неизвестное имя — честный отказ со ссылкой на координаты.
    @Test func unknownNameIsHonest() async {
        let call = SophieToolCall(tool: .distanceEta, targetLat: nil,
                                targetLon: nil, fromLat: 1, fromLon: 1,
                                targetName: "Загогулинск-Заповедный")
        let result = await SophieTools.runDistanceEta(call)
        #expect(result.summary.contains("нет пункта"))
    }
}

// MARK: - Перф-замеры (вне обычного прогона)

/// Порог скорости — ОТДЕЛЬНАЯ перф-сьюта, в обычном прогоне пропускается
/// (решение 29.07: тест, краснеющий от соседнего процесса на машине,
/// приучает игнорировать красное). Запуск: переменная окружения
/// RM_PERF=1 у test-раннера. Функциональная корректность nearest покрыта
/// остальными тестами GazetteerTests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RM_PERF"] == "1",
                "перф-замер газетира: включается только при RM_PERF=1"))
struct GazetteerPerfTests {

    @Test func nearestIsFastEnough() {
        _ = GazetteerStore.shared.nearest(lat: 0, lon: 0)   // прогрев/загрузка
        // Минимум из трёх замеров: параллельные тесты грузят CPU
        // симулятора, одиночный замер флакает
        var bestMs = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let t0 = DispatchTime.now()
            _ = GazetteerStore.shared.nearest(lat: 33.5, lon: -7.6)
            bestMs = min(bestMs, Double(DispatchTime.now().uptimeNanoseconds
                                        - t0.uptimeNanoseconds) / 1e6)
        }
        print("газетир: nearest за \(String(format: "%.1f", bestMs)) мс "
            + "на \(GazetteerStore.shared.count) записях")
        #expect(bestMs < 50, "перебор занял \(bestMs) мс")
    }
}
