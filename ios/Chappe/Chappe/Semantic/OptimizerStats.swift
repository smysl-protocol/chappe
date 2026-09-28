import Foundation

// ============================================================================
// Локальная статистика замен оптимизатора (часть 2 брифа 08.08).
//
// Зачем: если оптимизатор раз за разом заменяет одни и те же слова —
// это прямой список кандидатов в словарь Smysl.
//
// КЛАСС ДАННЫХ — тот же, что журнал Софи: это следы того, как человек
// пишет. Поэтому:
//   - файл лежит в Application Support рядом с прочими личными данными;
//   - НЕ попадает в TransportDiary, в отчёты и в отправку;
//   - не экспортируется автоматически никуда и никогда;
//   - переносится в словарь только руками владельца, глазами, с телефона.
// Замок на это — tools/dev/optimizer_stats_lint.py: он падает, если тип
// OptimizerStats упомянут в транспорте, дневнике или путях выгрузки.
// ============================================================================

nonisolated enum OptimizerStats {

    private static let fileName = "optimizer_stats.json"

    private static func url() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return base.appendingPathComponent(fileName)
    }

    /// Слова, которые оптимизатор убрал/заменил, с числом случаев.
    static func load() -> [String: Int] {
        guard let url = try? url(),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: Int].self,
                                                   from: data)
        else { return [:] }
        return dict
    }

    /// Записать разницу словарей: что было в исходнике и пропало в
    /// переписанном. Именно эти слова словарь не покрывает.
    ///
    /// Собирается ТОЛЬКО в DEBUG (решение владельца 08.08): смотреть и
    /// удалять этот список можно лишь с Dev-экрана, а его в Release нет.
    /// Значит, на чужом устройстве не должно лежать ничего, чего человек
    /// не видит и не может стереть. Для пополнения словаря хватает
    /// собственных прогонов владельца.
    static func record(source: String, rewritten: String) {
        #if DEBUG
        let src = words(source), out = Set(words(rewritten))
        let dropped = src.filter { !out.contains($0)
            && !SemanticEncoder.lexiconCovers($0) }
        guard !dropped.isEmpty else { return }
        var stats = load()
        for word in dropped { stats[word, default: 0] += 1 }
        guard let url = try? url(),
              let data = try? JSONEncoder().encode(stats) else { return }
        try? data.write(to: url, options: .atomic)
        #endif
    }

    /// Верхушка списка для Dev-экрана (смотрит владелец, глазами).
    static func top(_ limit: Int = 20) -> [(word: String, count: Int)] {
        load().sorted { $0.value > $1.value || ($0.value == $1.value
                                                && $0.key < $1.key) }
            .prefix(limit)
            .map { (word: $0.key, count: $0.value) }
    }

    static func reset() {
        if let url = try? url() { try? FileManager.default.removeItem(at: url) }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "-" })
            .map(String.init)
            .filter { $0.count > 2 }
    }
}
