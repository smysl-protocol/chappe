import Foundation
import CryptoKit

// ============================================================================
// Память Софи (шаг 3): три вида — семантическая (факты), эпизодическая
// (события), процедурная (курируемые инструкции) — по мотивам памяти
// waku-agent, под ограничения телефона.
//
// Хранение: ОДИН шифрованный файл (ChaChaPoly — тот же AEAD, что E2E
// проекта; ключ — SophieMemoryKey из Keychain). Почему не SQLCipher:
// новая SPM-зависимость и правка pbxproj — отдельной задачей; системный
// SQLite целиком не шифруется, FTS по шифротексту не работает. Объём
// памяти мал и ограничен потолками КОДОМ (правило №3 непреложных),
// поэтому файл читается в память целиком, поиск — по расшифрованному.
// Хранилище за узким API — бэкенд сменяем, харнесс не заметит.
//
// Файл живёт в Application Support/Sophie/ → «Начать заново» стирает его
// вместе с каталогом (SophiePurge), а уничтожение ключа делает любые
// уцелевшие копии шумом (криптостирание).
//
// Битый файл или чужой ключ = ПУСТАЯ память, не крэш: после
// криптостирания приложение обязано работать как с чистого листа.
// ============================================================================

nonisolated struct SophieFact: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var subject: String
    var content: String
    /// Откуда факт: consolidation | manual (потом — enum источников).
    var source: String
    var createdAt: Date
}

nonisolated struct SophieEpisode: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var happenedAt: Date
    var summary: String
}

nonisolated struct SophieInstruction: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var body: String
}

actor SophieMemoryStore {

    /// Потолки — правило №3: у каждого повторяемого поля есть потолок.
    /// Переполнение вытесняет старейшие записи.
    static let maxFacts = 500
    static let maxEpisodes = 200

    nonisolated struct Records: Codable, Equatable, Sendable {
        var facts: [SophieFact] = []
        var episodes: [SophieEpisode] = []
        var instructions: [SophieInstruction] = []
        /// Курсоры консолидации по ключам чатов (шаг 3.3): сколько
        /// сообщений уже свёрнуто в факты. Optional — файлы памяти,
        /// записанные до 3.3, декодятся без потери (nil = нули).
        var consolidationCursors: [String: Int]?
    }

    private let fileURL: URL
    private let key: SymmetricKey
    private var records: Records

    /// fileURL и key инжектируются (тест — temp-мир + случайный ключ).
    init(fileURL: URL, key: SymmetricKey) {
        self.fileURL = fileURL
        self.key = key
        self.records = Self.load(fileURL: fileURL, key: key) ?? Records()
    }

    /// Боевое открытие: файл в каталоге Sophie, ключ из Keychain.
    /// nil — Keychain отказал в ключе (память недоступна, не крэш).
    static func open() -> SophieMemoryStore? {
        guard let key = SophieMemoryKey.ensure(),
              let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Sophie", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return SophieMemoryStore(
            fileURL: dir.appendingPathComponent("memory.enc"), key: key)
    }

    // MARK: Факты

    func addFact(subject: String, content: String, source: String) {
        records.facts.append(SophieFact(id: UUID(), subject: subject,
                                        content: content, source: source,
                                        createdAt: Date()))
        if records.facts.count > Self.maxFacts {
            records.facts.removeFirst(records.facts.count - Self.maxFacts)
        }
        persist()
    }

    func facts() -> [SophieFact] { records.facts }

    func deleteFact(id: UUID) {
        records.facts.removeAll { $0.id == id }
        persist()
    }

    /// Добавить факт, если точно такого (subject+content) ещё нет.
    /// Дедуп нужен консолидации: одна и та же тема всплывает в разных
    /// разговорах, память не должна зарастать копиями.
    /// Возвращает true, если факт добавлен.
    @discardableResult
    func addFactDeduped(subject: String, content: String,
                        source: String) -> Bool {
        guard !records.facts.contains(where: {
            $0.subject == subject && $0.content == content
        }) else { return false }
        addFact(subject: subject, content: content, source: source)
        return true
    }

    // MARK: Курсоры консолидации (шаг 3.3)

    func consolidationCursor(for key: String) -> Int {
        records.consolidationCursors?[key] ?? 0
    }

    func setConsolidationCursor(_ value: Int, for key: String) {
        var cursors = records.consolidationCursors ?? [:]
        cursors[key] = value
        records.consolidationCursors = cursors
        persist()
    }

    // MARK: Эпизоды

    func addEpisode(happenedAt: Date, summary: String) {
        records.episodes.append(SophieEpisode(id: UUID(),
                                              happenedAt: happenedAt,
                                              summary: summary))
        if records.episodes.count > Self.maxEpisodes {
            records.episodes.removeFirst(records.episodes.count - Self.maxEpisodes)
        }
        persist()
    }

    func episodes() -> [SophieEpisode] { records.episodes }

    func deleteEpisode(id: UUID) {
        records.episodes.removeAll { $0.id == id }
        persist()
    }

    // MARK: Поиск (шаг 3.2)

    /// Поиск по фактам: TF-IDF без эмбеддингов (паттерн waku: BM25 по
    /// FTS — у нас память мала и уже в RAM, хватает честного TF-IDF).
    func searchFacts(_ query: String, topK: Int = 4) -> [SophieFact] {
        ranked(records.facts, query: query, topK: topK,
               text: { $0.subject + " " + $0.content },
               tieBreak: { _, _ in false })
    }

    /// Поиск по эпизодам; при равной релевантности — свежие первыми.
    func searchEpisodes(_ query: String, topK: Int = 3) -> [SophieEpisode] {
        ranked(records.episodes, query: query, topK: topK,
               text: { $0.summary },
               tieBreak: { $0.happenedAt > $1.happenedAt })
    }

    /// Токены: lower-case, ё→е, буквы/цифры, длина ≥2, лёгкий стем.
    nonisolated static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
            .map(stem)
    }

    /// Лёгкий стеммер (22.08, снимает ограничение v1 «живу≠живёт»):
    /// срез ОДНОГО типового окончания при основе ≥3 букв. Это не Портер —
    /// сближение форм для TF-IDF; редкие ложные слияния («ради»≈«радио»)
    /// дёшевы, пропуск релевантного факта дорог.
    nonisolated static func stem(_ token: String) -> String {
        let endings = ["ется", "ится", "иями", "ями", "ами",
                       "ешь", "ишь", "ете", "ите", "ого", "его",
                       "ому", "ему", "ыми", "ими",
                       "ах", "ях", "ов", "ев", "ей", "ой", "ом", "ем",
                       "ут", "ют", "ит", "ат", "ят", "ет", "ла", "ло",
                       "ли", "ть",
                       "у", "ю", "а", "я", "ы", "и", "е", "о"]
        for ending in endings
        where token.hasSuffix(ending) && token.count - ending.count >= 3 {
            return String(token.dropLast(ending.count))
        }
        return token
    }

    /// TF-IDF: sum(tf · log(1 + N/df)) по токенам запроса; нулевой
    /// счёт отсекается — нерелевантное не подмешивается «за компанию».
    private func ranked<T>(_ items: [T], query: String, topK: Int,
                           text: (T) -> String,
                           tieBreak: (T, T) -> Bool) -> [T] {
        let queryTokens = Set(Self.tokenize(query))
        guard !queryTokens.isEmpty, !items.isEmpty else { return [] }
        let docs = items.map { Self.tokenize(text($0)) }
        var df: [String: Int] = [:]
        for tokens in docs {
            for q in queryTokens where tokens.contains(q) {
                df[q, default: 0] += 1
            }
        }
        let n = Double(items.count)
        let scored: [(item: T, score: Double)] = zip(items, docs).map { item, tokens in
            var score = 0.0
            for q in queryTokens {
                let tf = tokens.count(where: { $0 == q })
                if tf > 0, let d = df[q] {
                    score += Double(tf) * log(1 + n / Double(d))
                }
            }
            return (item, score)
        }
        return scored.filter { $0.score > 0 }
            .sorted {
                $0.score != $1.score ? $0.score > $1.score
                                     : tieBreak($0.item, $1.item)
            }
            .prefix(topK).map(\.item)
    }

    // MARK: Шифрованный персист

    private func persist() {
        guard let plain = try? JSONEncoder().encode(records),
              let box = try? ChaChaPoly.seal(plain, using: key)
        else { return }
        try? box.combined.write(to: fileURL, options: .atomic)
    }

    /// Любой сбой (нет файла, битый файл, ЧУЖОЙ КЛЮЧ после
    /// криптостирания) → nil → пустая память, не крэш.
    private static func load(fileURL: URL, key: SymmetricKey) -> Records? {
        guard let raw = try? Data(contentsOf: fileURL),
              let box = try? ChaChaPoly.SealedBox(combined: raw),
              let plain = try? ChaChaPoly.open(box, using: key),
              let records = try? JSONDecoder().decode(Records.self, from: plain)
        else { return nil }
        return records
    }
}
