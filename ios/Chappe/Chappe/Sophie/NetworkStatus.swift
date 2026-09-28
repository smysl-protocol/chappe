import Foundation

// ============================================================================
// NetworkStatus — детерминированная карточка состояния сети (WP3, 02.08).
//
// Повод — реальный диалог: на вопрос об узлах модель ответила «узлы
// работают только при стабильном соединении», «сейчас проверю»,
// «я проверила — узлов нет». Ничего она не проверяла и проверить не
// могла: доступа к радио у модели нет и не будет (LLM вне доверенного
// тракта). Это тот же класс отказа, что «старинные шапки»: свободная
// генерация там, где нужны факты.
//
// Решение — НЕ дать модели данные радио, а перехватить вопрос ДО модели
// (непреложное №9: правила в промпте не работают, работает код).
// Карточку собирает код из NodeRegistry/живого источника, рендерит UI.
// Модель в этом пути не вызывается вообще.
// ============================================================================

nonisolated enum NetworkStatus {

    struct Snapshot: Equatable {
        /// nil — живого соединения сейчас нет данных (сервис не активен).
        var connectedNow: Bool?
        var nodeName: String?
        var region: String?
        /// Размер NodeDB узла при последнем чтении (сколько узлов он знает).
        var knownNodeCount: Int?
        var lastContact: Date?
        var regionWarnings: [String] = []
    }

    /// Живой источник состояния. По умолчанию — последние известные
    /// факты из NodeRegistry; долгоживущий BLE-сервис (WP2) подменяет
    /// на реальное состояние соединения.
    @MainActor static var liveSource: () -> Snapshot = defaultSnapshot

    @MainActor static func defaultSnapshot() -> Snapshot {
        // Самый свежий из известных узлов; связь «сейчас» неизвестна —
        // без живого сервиса врать «подключён/нет» нельзя
        guard let latest = NodeRegistry.load().values
            .max(by: { $0.lastSeen < $1.lastSeen }) else {
            return Snapshot(connectedNow: nil)
        }
        return Snapshot(connectedNow: nil,
                        nodeName: latest.name,
                        region: latest.region,
                        knownNodeCount: latest.nodeCount,
                        lastContact: latest.lastSeen,
                        regionWarnings: NodeRegistry.warnings(
                            region: latest.region,
                            expected: NodeRegistry.expectedRegion(),
                            others: []))
    }

    // MARK: Детектор вопросов о состоянии сети

    /// Слова, однозначно указывающие на радио-домен.
    static let hardStems = ["узл", "узел", "узла", "радиоузл",
                            "meshtastic", "мештастик", "lora", "лора"]
    /// Сетевые слова, требующие рядом сигнала «вопрос о состоянии».
    static let softStems = ["связ", "сет", "сигнал", "соединен",
                            "подключ", "доставк", "антенн", "радио",
                            "покрыти", "ретрансл", "сообщен", "отправ"]
    static let stateCues = ["есть", "нет", "работа", "провер", "статус",
                            "состоян", "сейчас", "почему", "упал",
                            "пропал", "потерял", "теря", "ловит",
                            "видит", "видно", "дошл", "дошел", "дошёл",
                            "доставл", "подключ", "включ",
                            "оборвал", "слыш"]

    /// Вопрос о состоянии сети/узлов/доставки? Детерминированный код,
    /// не модель. «Узлы» перехватываются всегда (чисто радийное слово),
    /// мягкие термины — только вместе с сигналом состояния, чтобы
    /// «какая связь между Софи и Клодом» уходило модели как раньше.
    static func isNetworkQuestion(_ text: String) -> Bool {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if words.contains(where: { w in
            hardStems.contains { w.hasPrefix($0) } }) {
            return true
        }
        let hasSoft = words.contains { w in
            softStems.contains { w.hasPrefix($0) } }
        let hasCue = words.contains { w in
            stateCues.contains { w.hasPrefix($0) } }
        return hasSoft && hasCue
    }

    // MARK: Текст карточки — только факты, никаких «я проверила»

    static func cardText(_ s: Snapshot, now: Date = Date()) -> String {
        var lines: [String] = []
        switch s.connectedNow {
        case true:
            lines.append("Радиоустройство: подключено"
                + (s.nodeName.map { " («\($0)»)" } ?? ""))
        case false:
            lines.append("Радиоустройство: не подключено"
                + (s.nodeName.map { " (последнее — «\($0)»)" } ?? ""))
        default:
            lines.append(s.nodeName.map {
                "Радиоустройство: соединение сейчас не активно (последнее — «\($0)»)"
            } ?? "Радиоустройство ещё ни разу не подключалось")
        }
        if let region = s.region {
            lines.append("Страна и частоты устройства: \(region)")
        }
        lines.append(contentsOf: s.regionWarnings)
        if let count = s.knownNodeCount {
            lines.append("Устройство видит рядом: \(count)")
        }
        if let last = s.lastContact {
            lines.append("Последний ответ устройства: \(relative(last, now: now))")
        }
        lines.append("Подключение и проверка — Настройки → Дальняя связь.")
        return lines.joined(separator: "\n")
    }

    static func relative(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "меньше минуты назад"
        case ..<60: return "\(minutes) мин назад"
        case ..<(48 * 60): return "\(minutes / 60) ч назад"
        default: return "\(minutes / 60 / 24) дн назад"
        }
    }
}
