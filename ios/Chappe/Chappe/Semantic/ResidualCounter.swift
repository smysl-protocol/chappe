import Foundation

// ============================================================================
// Residual-счётчик — механизм роста словаря по факту использования
// (semantic_compression §6: «частый оборот → новый код»).
//
// При каждой ПОДТВЕРЖДЁННОЙ человеком семантической отправке копим
// счётчик literal-слов (непокрытых словарём). Это словарная телеметрия,
// не переписка: хранится локально (Application Support, из бэкапа
// исключено), никуда не передаётся; выгрузка — только вручную из Dev.
//
// Приватность: имена (esc_name) и числа (esc_number) в счётчик НЕ
// попадают — только словарные кандидаты.
// ============================================================================

nonisolated enum ResidualCounter {

    static func fileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let url = base.appendingPathComponent("residual_counter.json")
        return url
    }

    static func load() -> [String: Int] {
        guard let url = try? fileURL(),
              let data = try? Data(contentsOf: url),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return counts
    }

    private static func save(_ counts: [String: Int]) {
        guard let url = try? fileURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(counts).write(to: url, options: .atomic)
        try? ModelStore.excludeFromBackup(url)
    }

    /// Учесть подтверждённую отправку: одно слово считается один раз
    /// на отправку (счётчик «отправок со словом», не вхождений).
    static func record(units: [RMCodec.Unit]) {
        let words = literalWords(units)
        guard !words.isEmpty else { return }
        var counts = load()
        for word in words {
            counts[word, default: 0] += 1
        }
        save(counts)
    }

    /// Словарные кандидаты из юнитов: только literal, нормализация как
    /// в матчере (lowercase, разбивка по не-буквам); имена и числа мимо.
    static func literalWords(_ units: [RMCodec.Unit]) -> Set<String> {
        var words = Set<String>()
        for unit in units {
            guard case .lit(let run) = unit else { continue }   // name/num мимо
            for token in run.lowercased()
                .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "_" }) {
                let word = String(token)
                // чисто служебные огрызки не копим
                if word.count >= 2, !word.allSatisfy({ $0 == "_" || $0 == "'" }) {
                    words.insert(word)
                }
            }
        }
        return words
    }

    /// Топ слов по счётчику (для экрана и экспорта).
    static func top(_ n: Int = 50) -> [(word: String, count: Int)] {
        load()
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(n)
            .map { ($0.key, $0.value) }
    }

    /// Экспорт для итерации словаря (ручной отбор кандидатов).
    static func exportJSON() throws -> URL {
        let counts = load()
        let payload: [String: Any] = [
            "purpose": "кандидаты в словарь R+M — residual-счётчик",
            "note": "локальная словарная телеметрия; имена и числа не копятся",
            "words": counts,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("residual_counter_export.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func reset() {
        save([:])
    }
}
