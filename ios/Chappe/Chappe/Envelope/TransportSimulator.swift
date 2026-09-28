import Foundation

// ============================================================================
// Симулятор LoRa-канала — порт sim/transport_sim.py.
//
// Настоящее радио теряет пакеты, задерживает, переставляет порядок и
// дублирует (в меше пакет может прийти двумя путями). Пока железо не
// приехало, все эти «беды» изображает этот класс.
//
// Время виртуальное: канал двигает часы сам, ничего не «спит» — симуляция
// мгновенная и воспроизводимая: один seed → одна последовательность событий.
// (Генератор свой, SplitMix64: системный в Swift не сидируется. Совпадение
// последовательностей с Python не требуется — там свой генератор; важна
// воспроизводимость внутри каждой реализации.)
// ============================================================================

/// Детерминированный генератор случайности (SplitMix64).
nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Равномерное [0, 1).
    mutating func uniform() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9007199254740992.0)   // 2^-53
    }

    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + uniform() * (hi - lo)
    }
}

/// Односторонний канал «отправитель → получатель» со всеми бедами радио.
nonisolated final class LoRaChannel {

    struct Stats {
        var sent = 0        // попыток отправки
        var delivered = 0   // доставлено получателю (включая дубликаты)
        var lost = 0        // потеряно в эфире
        var duplicated = 0  // создано дубликатов
        var oversize = 0    // отброшено: больше лимита размера
    }

    let loss: Double        // вероятность потери пакета
    let duplicate: Double   // вероятность дубликата
    let reorder: Double     // вероятность «застревания» (перестановка порядка)
    let delayMin: Double    // задержка доставки, секунды
    let delayMax: Double
    let maxPayload: Int     // лимит полезной нагрузки (200 байт как у LoRa)

    private(set) var now = 0.0          // виртуальные часы канала
    private(set) var stats = Stats()
    private var rng: SeededRandom
    private var seq = 0                 // сквозной номер для устойчивой сортировки
    private var inFlight: [(arriveAt: Double, seq: Int, packet: [UInt8])] = []

    init(loss: Double = 0, duplicate: Double = 0, reorder: Double = 0,
         delayMin: Double = 0.1, delayMax: Double = 1.0,
         maxPayload: Int = Envelope.maxPayload, seed: UInt64 = 0) {
        precondition((0...1).contains(loss) && (0...1).contains(duplicate)
                     && (0...1).contains(reorder),
                     "вероятности должны быть от 0.0 до 1.0")
        precondition(delayMin >= 0 && delayMax >= delayMin,
                     "нужно 0 ≤ delayMin ≤ delayMax")
        self.loss = loss
        self.duplicate = duplicate
        self.reorder = reorder
        self.delayMin = delayMin
        self.delayMax = delayMax
        self.maxPayload = maxPayload
        self.rng = SeededRandom(seed: seed)
    }

    // MARK: Отправка

    /// Отправляет пакет. Возвращает false, если пакет больше лимита —
    /// такое радио не примет, резать на фрагменты обязан отправитель.
    @discardableResult
    func send(_ packet: [UInt8]) -> Bool {
        stats.sent += 1
        guard packet.count <= maxPayload else {
            stats.oversize += 1
            return false
        }
        launch(packet)
        // Дубликат: копия летит независимо — своя задержка, свой риск потери
        if rng.uniform() < duplicate {
            stats.duplicated += 1
            launch(packet)
        }
        return true
    }

    private func launch(_ packet: [UInt8]) {
        if rng.uniform() < loss {
            stats.lost += 1
            return
        }
        var delay = rng.uniform(delayMin, delayMax)
        // «Застрявший» пакет придёт позже отправленных после него
        if rng.uniform() < reorder {
            delay += delayMax * 2
        }
        seq += 1
        inFlight.append((now + delay, seq, packet))
    }

    // MARK: Получение

    /// Прокручивает время вперёд и отдаёт всё, что долетело, в порядке
    /// ПРИБЫТИЯ — из-за случайных задержек он отличается от порядка отправки.
    func deliverAll() -> [[UInt8]] {
        inFlight.sort { ($0.arriveAt, $0.seq) < ($1.arriveAt, $1.seq) }
        let out = inFlight.map(\.packet)
        if let last = inFlight.last {
            now = max(now, last.arriveAt)
        }
        stats.delivered += inFlight.count
        inFlight.removeAll()
        return out
    }

    var inFlightCount: Int { inFlight.count }

    /// Отчёт о работе канала, по-русски.
    var report: String {
        "отправлено: \(stats.sent), доставлено: \(stats.delivered), "
        + "потеряно: \(stats.lost), дубликатов: \(stats.duplicated), "
        + "отброшено по размеру: \(stats.oversize)"
    }
}
