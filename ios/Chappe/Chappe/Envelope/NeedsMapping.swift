import Foundation

// ============================================================================
// Мост между миром модели (enum-строки схемы SOS-извлечения) и миром
// envelope (коды и биты §5–§6 спеки).
//
// Соответствие needs — ЕДИНСТВЕННОЕ место в Swift; источник истины —
// tests/needs_mapping.json, тест EnvelopeTests сверяет их между собой
// (и Python делает то же со своей стороны), чтобы таблицы не разъезжались.
// ============================================================================

nonisolated enum NeedsMapping {

    /// enum-строка модели → номер бита в маске needs (§6).
    /// fuel и shelter — биты 12 и 13, заняты из резерва 25.07.2026.
    static let modelToBit: [SOSReport.Need: Int] = [
        .bandages: 0,
        .water: 1,
        .food: 2,
        .boat: 3,
        .vehicle: 4,
        .doctor: 5,
        .medicine: 6,
        .evacuation: 7,
        .fuel: 12,
        .shelter: 13,
    ]

    /// Номер бита → русское название (для экрана). Полный справочник §6,
    /// включая позиции, которых нет в enum модели (связь, тепло и т.д.).
    static let bitNames: [Int: String] = [
        0: "бинты / перевязка",
        1: "вода",
        2: "еда",
        3: "лодка",
        4: "транспорт (наземный)",
        5: "врач / медик",
        6: "лекарства",
        7: "эвакуация",
        8: "связь",
        9: "тепло / одежда",
        10: "инструмент",
        11: "помощь в переноске",
        12: "топливо",
        13: "укрытие",
        15: "другое (см. хвост)",
    ]

    static let severityNames: [Int: String] = [
        0: "низкая", 1: "средняя", 2: "высокая", 3: "критическая",
    ]

    static let injuryNames: [Int: String] = [
        0: "нет травмы", 1: "кровотечение", 2: "перелом", 3: "ожог",
        4: "укус животного/змеи", 5: "травма головы", 6: "без сознания",
        7: "утопление", 8: "отравление", 15: "другое",
    ]

    // MARK: SOSReport (вывод модели) → SOSMessage (пакет)

    /// severity модели → код §5.
    static func severityCode(_ s: SOSReport.Severity) -> Int {
        switch s {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        }
    }

    /// injury модели → код §5. У envelope есть коды, которых нет в enum
    /// модели (укус, утопление, отравление) — маппинг в эту сторону полный.
    static func injuryCode(_ i: SOSReport.Injury) -> Int {
        switch i {
        case .none: 0
        case .bleeding: 1
        case .fracture: 2
        case .burn: 3
        case .head: 5
        case .unconscious: 6
        case .other: 15
        }
    }

    /// Собирает envelope-пакет SOS из результата извлечения модели.
    /// Координаты приходят снаружи (GPS или заглушка) — модель координат
    /// не касается никогда.
    static func makeSOSMessage(from report: SOSReport,
                               msgID: UInt16,
                               lat: Double?, lon: Double?) -> SOSMessage {
        SOSMessage(
            msgID: msgID,
            severity: severityCode(report.severity),
            peopleCount: min(report.peopleCount, Envelope.peopleMany),
            injury: injuryCode(report.injury),
            hopsLeft: 3,
            lat: lat, lon: lon,
            needs: Set(report.needs.compactMap { modelToBit[$0] })
        )
    }
}
