//
//  ModelSchedulerTests.swift
//  RMTests
//
//  Планировщик модели (sophie_presence §5, фаза 1): порядок по приоритетам,
//  мгновенное вытеснение P3, отмена активной генерации (стоп P2).
//

import Foundation
import Testing
@testable import Chappe

/// Мок-провайдер: «генерация» крутится, пока её не отменят или не
/// истечёт лимит циклов. Записывает порядок запусков в общий журнал.
actor MockProvider {
    nonisolated let kind: LLMProviderKind = .local
    nonisolated let capabilities: LLMCapabilities = [.cancellation]
    private(set) var isLoaded = false
    private nonisolated let cancelFlag = AtomicFlag()

    let log: MockLog

    init(log: MockLog) { self.log = log }

    func load(_ config: LLMModelConfig) async throws { isLoaded = true }
    func unload() async { isLoaded = false }

    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        cancelFlag.clear()
        await log.append("start:\(request.prompt)")
        // maxTokens используется как длительность «генерации» в тиках по 5 мс
        for _ in 0..<request.maxTokens {
            if cancelFlag.isSet || Task.isCancelled {
                await log.append("cancelled:\(request.prompt)")
                throw LLMError.cancelled
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await log.append("done:\(request.prompt)")
        return LLMResponse(text: "ok:\(request.prompt)", tokensGenerated: 1,
                           tokensPerSecond: 0, finishReason: .stop)
    }

    func generateStructured(_ request: LLMRequest,
                            spec: StructuredSpec) async throws -> LLMResponse {
        throw LLMError.structuredOutputUnsupported
    }

    nonisolated func cancelActiveGeneration() { cancelFlag.set() }
}

/// Журнал событий мока (актор — потокобезопасно).
actor MockLog {
    private(set) var events: [String] = []
    func append(_ e: String) { events.append(e) }
}

private func makeScheduler(_ log: MockLog) -> ModelScheduler {
    ModelScheduler(makeProvider: { MockProvider(log: log) })
}

struct ModelSchedulerTests {

    /// P0–P2 мгновенно вытесняет работающий P3.
    @Test func p3IsPreemptedByHigherPriority() async throws {
        let log = MockLog()
        let scheduler = makeScheduler(log)

        // P3 «крутится долго» (1000 тиков ≈ 5 с — не дождёмся, вытесним)
        let background = Task {
            try await scheduler.withProvider(.background) { p in
                try await p.generate(LLMRequest(prompt: "p3", maxTokens: 1000))
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)   // P3 точно стартовал

        // P0 прилетает — P3 обязан отмениться, P0 выполниться
        let sos = try await scheduler.withProvider(.sos) { p in
            try await p.generate(LLMRequest(prompt: "p0", maxTokens: 2))
        }
        #expect(sos.text == "ok:p0")

        let p3Result = await background.result
        guard case .failure(let err) = p3Result, case LLMError.cancelled = err else {
            Issue.record("P3 обязан завершиться LLMError.cancelled, получено: \(p3Result)")
            return
        }
        let events = await log.events
        #expect(events.contains("cancelled:p3"), "события: \(events)")
        #expect(events.firstIndex(of: "cancelled:p3")! < events.firstIndex(of: "start:p0")!,
                "P0 стартует только после освобождения слота: \(events)")
    }

    /// В очереди P1 обгоняет P3, внутри приоритета — FIFO.
    @Test func queueOrdersByPriorityThenFIFO() async throws {
        let log = MockLog()
        let scheduler = makeScheduler(log)

        // Занимаем слот P2-задачей
        let holder = Task {
            try await scheduler.withProvider(.interactive) { p in
                try await p.generate(LLMRequest(prompt: "hold", maxTokens: 60))
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Ставим в очередь: сперва P3, потом два P1
        let t3 = Task {
            try await scheduler.withProvider(.background) { p in
                try await p.generate(LLMRequest(prompt: "p3", maxTokens: 1))
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let t1a = Task {
            try await scheduler.withProvider(.outgoing) { p in
                try await p.generate(LLMRequest(prompt: "p1a", maxTokens: 1))
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let t1b = Task {
            try await scheduler.withProvider(.outgoing) { p in
                try await p.generate(LLMRequest(prompt: "p1b", maxTokens: 1))
            }
        }

        _ = try await holder.value
        _ = try await t1a.value
        _ = try await t1b.value
        _ = try await t3.value

        let events = await log.events
        let starts = events.filter { $0.hasPrefix("start:") }
        #expect(starts == ["start:hold", "start:p1a", "start:p1b", "start:p3"],
                "порядок запусков: \(starts)")
    }

    /// cancelActive прерывает работающий интерактив (кнопка «Стоп»).
    @Test func cancelActiveStopsRunningGeneration() async throws {
        let log = MockLog()
        let scheduler = makeScheduler(log)

        let chat = Task {
            try await scheduler.withProvider(.interactive) { p in
                try await p.generate(LLMRequest(prompt: "p2", maxTokens: 1000))
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await scheduler.cancelActive()

        let result = await chat.result
        guard case .failure(let err) = result, case LLMError.cancelled = err else {
            Issue.record("ожидалась LLMError.cancelled, получено: \(result)")
            return
        }
        // Слот освободился — следующий вызов проходит
        let after = try await scheduler.withProvider(.outgoing) { p in
            try await p.generate(LLMRequest(prompt: "after", maxTokens: 1))
        }
        #expect(after.text == "ok:after")
    }
}

extension MockProvider: LLMProvider {}
