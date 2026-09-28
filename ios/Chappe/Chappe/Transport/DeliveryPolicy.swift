import Foundation

// ============================================================================
// Маршрутная политика доставки (блок 1, спека владельца 10.08).
//
// Из полевого разбора 09.08 (сверка обеих сторон): тракт ЗАЛИПАЛ на
// радио — «радио сконфигурировано» принималось за «радио живо», очередь
// лила попытки в мёртвый узел до похорон сообщения, хотя интернет был
// включён. Спека фикса:
//  - недоставленное ретраится по ВСЕМ ЖИВЫМ транспортам до
//    подтверждённой доставки;
//  - приоритет: интернет/«рядом» первыми, радио — ПОСЛЕДНИМ (эфир
//    дорог); радио присоединяется, когда быстрых путей нет или они
//    буксуют дольше radioJoinsAfter;
//  - к мёртвому транспорту не пиннимся: появился лучший — переключаемся
//    (решение пересчитывается каждый тик насоса от ЖИВОСТИ путей).
//
// Чистая функция без IO — решение маршрута закрыто замком целиком.
// ============================================================================

nonisolated enum DeliveryPolicy {

    /// Сколько секунд быстрые пути пробуют сами, прежде чем к ним
    /// присоединится радио (быстрые обычно доставляют за секунды;
    /// буксовка дольше — вероятно, получателю доступен только эфир).
    static let radioJoinsAfter: TimeInterval = 30

    /// Мега-6 (14.08): при живом «рядом» релей присоединяется только
    /// при буксовке — зеркало правила радио. Полевой вечер 13.08:
    /// оба быстрых пути стреляли одновременно, ack-гонка красила
    /// метки вперемешку «рядом»↔«через интернет» в одном чате, релей
    /// возил дубли зря.
    static let relayJoinsAfter: TimeInterval = 10

    struct Verdict: Equatable {
        var radio: Bool
        var relay: Bool
        var nearby: Bool
        var any: Bool { radio || relay || nearby }
    }

    /// Маршруты ЭТОЙ попытки. `relayEligible` — сообщению есть что
    /// класть на релей и оно ещё не лежит в ящике (судьбу лежащего
    /// решает наблюдение ящика, не насос). `manual` — ручной выбор
    /// транспортов (постановка 10.08): человек уже выбрал галочками,
    /// авто-приоритет «радио последним» НЕ применяется — отмеченный
    /// LoRa шлёт сразу (блок 2: форс побеждает авто-выбор).
    static func routes(radioAlive: Bool, relayAlive: Bool,
                       nearbyAlive: Bool, relayEligible: Bool,
                       firstAttemptAt: Date?, now: Date,
                       manual: Bool = false) -> Verdict {
        let relayPossible = relayAlive && relayEligible
        if manual {
            return Verdict(radio: radioAlive, relay: relayPossible,
                           nearby: nearbyAlive)
        }
        // «рядом» — первым из быстрых: релей присоединяется только при
        // буксовке (мега-6: одновременный залп обоих путей давал
        // ack-гонку меток и дубли на релее)
        let nearbyStalling = firstAttemptAt.map {
            now.timeIntervalSince($0) >= relayJoinsAfter
        } ?? false
        let relay = relayPossible && (!nearbyAlive || nearbyStalling)
        let fastAlive = relay || nearbyAlive
        let fastStalling = firstAttemptAt.map {
            now.timeIntervalSince($0) >= radioJoinsAfter
        } ?? false
        // радио — последним: только когда быстрых нет или они буксуют
        let radio = radioAlive && (!fastAlive || fastStalling)
        return Verdict(radio: radio, relay: relay, nearby: nearbyAlive)
    }
}
