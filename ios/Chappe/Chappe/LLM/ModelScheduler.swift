import Foundation

// ============================================================================
// ModelScheduler — единая очередь к модели (sophie_presence §5, фаза 1).
//
// Модель одна, желающих много. Все обращения к LLMProvider идут через
// этот актор: один слот исполнения, очередь с приоритетами, вытеснение.
//
//   P0 sos          SOS-конвейер (извлечение/подтверждение)
//   P1 outgoing     исходящее сообщение (пивот: человек ждёт отправки)
//   P2 interactive  интерактив Софи (её чаты; шёпот — следующая фаза)
//   P3 background   фоновые суммаризации (задач пока нет; вытесняется)
//
// Правило вытеснения: любой P0–P2 мгновенно отменяет работающий P3
// (cancelActiveGeneration → P3 завершается LLMError.cancelled и обязан
// уметь продолжиться позже чанками — sophie_presence §5 «фазность»).
// P0 не вытесняет P1/P2: генерации короткие, дешевле дождаться,
// чем терять работу; P0 просто первый в очереди.
// ============================================================================

nonisolated enum LLMPriority: Int, Comparable, Sendable {
    case sos = 0
    case outgoing = 1
    case interactive = 2
    case background = 3

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

actor ModelScheduler {

    /// Один общий планировщик приложения — как одна модель.
    static let shared = ModelScheduler()

    private let makeProvider: @Sendable () throws -> any LLMProvider
    private var provider: (any LLMProvider)?
    private(set) var lastLoadMillis: Double = 0

    private struct Waiter {
        let priority: LLMPriority
        let seq: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private var runningPriority: LLMPriority?
    private var waiters: [Waiter] = []
    private var seq = 0

    /// makeProvider инжектируется в тестах (мок вместо настоящего движка).
    init(makeProvider: @escaping @Sendable () throws -> any LLMProvider = {
        try LLMProviderFactory.make(LLMModelConfig.loadActive().providerKind)
    }) {
        self.makeProvider = makeProvider
    }

    // MARK: Единственная дверь к модели

    /// Захватывает слот по приоритету, гарантирует загруженный провайдер,
    /// выполняет работу. Слот держится на всё тело body — многошаговые
    /// операции (бенчмарк) не перемежаются чужими вызовами.
    func withProvider<T: Sendable>(
        _ priority: LLMPriority,
        _ body: @Sendable (any LLMProvider) async throws -> T
    ) async throws -> T {
        await acquire(priority)
        defer { release() }
        let provider = try await readyProvider()
        return try await body(provider)
    }

    /// Отменить текущую генерацию (кнопка «Стоп»; вытеснение делает это само).
    func cancelActive() {
        provider?.cancelActiveGeneration()
    }

    /// Прогрев: загрузить модель, если ещё не загружена.
    /// Возвращает время загрузки в мс (0 — уже была загружена).
    func preload() async throws -> Double {
        if let p = provider, await p.isLoaded { return 0 }
        _ = try await readyProvider()
        return lastLoadMillis
    }

    /// Конфиг сменился (dev-меню) — выгрузить и пересоздать при
    /// следующем вызове.
    func invalidateProvider() async {
        await provider?.unload()
        provider = nil
    }

    /// Активный конфиг локален? (гейт приватности Софи, sophie_presence §3)
    nonisolated static func isLocalProviderActive() -> Bool {
        LLMModelConfig.loadActive().allowsPrivateWhisper
    }

    // MARK: Слот и очередь

    private func acquire(_ priority: LLMPriority) async {
        if runningPriority == nil {
            runningPriority = priority
            return
        }
        // Вытеснение: P0–P2 мгновенно отменяет работающий P3
        if priority < .background, runningPriority == .background {
            provider?.cancelActiveGeneration()
        }
        seq += 1
        let mySeq = seq
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(Waiter(priority: priority, seq: mySeq, continuation: c))
        }
    }

    private func release() {
        // Следующий — высший приоритет, внутри приоритета FIFO
        guard let index = waiters.indices.min(by: {
            (waiters[$0].priority.rawValue, waiters[$0].seq)
                < (waiters[$1].priority.rawValue, waiters[$1].seq)
        }) else {
            runningPriority = nil
            return
        }
        let next = waiters.remove(at: index)
        runningPriority = next.priority
        next.continuation.resume()
    }

    private func readyProvider() async throws -> any LLMProvider {
        if let p = provider, await p.isLoaded { return p }
        let p = try makeProvider()
        let t0 = DispatchTime.now()
        try await p.load(LLMModelConfig.loadActive())
        lastLoadMillis = Double(DispatchTime.now().uptimeNanoseconds
                                - t0.uptimeNanoseconds) / 1e6
        provider = p
        return p
    }
}
