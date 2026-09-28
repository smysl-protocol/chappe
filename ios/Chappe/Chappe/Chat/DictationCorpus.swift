import Foundation

// ============================================================================
// Авто-корпус диктовок (п.3 брифа 31.07): live_2026-07-29 потерян,
// потому что записи жили только в моменте. Теперь приложение САМО
// складывает каждую диктовку в фикстуры: аудио, транскрипт, пивот,
// байты, рендер, решение гейта. Локально, с потолком по объёму,
// выгрузка целиком — кнопкой в Dev (File Sharing уже включён:
// папка появляется в Files → Chappe).
//
// Любой прогон владельца на телефоне сразу становится корпусом.
// ============================================================================

nonisolated struct DictationCorpusEntry: Codable {
    var id: String
    var date: Date
    var audioFile: String?        // имя файла рядом с jsonl (m4a)
    var transcript: String        // после пунктуатора и нормализатора
    var pivot: String?
    var blobBytes: Int?
    var blobHex: String?
    var rendered: String?
    /// semantic | text; для text — причина (какой гейт завернул)
    var decision: String?
    var reason: String?
}

nonisolated enum DictationCorpus {

    /// Потолки: старое вытесняется первым (FIFO).
    static let maxEntries = 300
    static let maxAudioBytes: Int64 = 200_000_000   // 200 МБ аудио

    static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("dictation_corpus",
                                              isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private static func indexURL() throws -> URL {
        try directory().appendingPathComponent("corpus.jsonl")
    }

    // MARK: Запись

    /// Начало записи корпуса: транскрипт + копия аудио (пока файл жив).
    /// Возвращает id для дозаполнения конвейерными полями.
    @discardableResult
    static func begin(transcript: String, audioURL: URL?) -> String? {
        guard !transcript.isEmpty else { return nil }
        var entry = DictationCorpusEntry(id: UUID().uuidString, date: Date(),
                                         transcript: transcript)
        if let audioURL, let dir = try? directory() {
            let name = "\(entry.id).m4a"
            if (try? FileManager.default.copyItem(
                    at: audioURL,
                    to: dir.appendingPathComponent(name))) != nil {
                entry.audioFile = name
            }
        }
        append(entry)
        enforceCaps()
        return entry.id
    }

    /// Дозаполнение конвейерными полями (пивот, байты, решение).
    static func complete(id: String, pivot: String?, blob: [UInt8]?,
                         rendered: String?, decision: String,
                         reason: String?) {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].pivot = pivot
        all[index].blobBytes = blob?.count
        all[index].blobHex = blob.map {
            $0.map { String(format: "%02x", $0) }.joined()
        }
        all[index].rendered = rendered
        all[index].decision = decision
        all[index].reason = reason
        save(all)
    }

    // MARK: Выгрузка (Dev)

    /// Копирует корпус в Documents/dictation_corpus_export —
    /// забирается с Мака через Files/Finder. Возвращает число записей.
    static func exportAll() throws -> Int {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        let dst = docs.appendingPathComponent("dictation_corpus_export",
                                              isDirectory: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: directory(), to: dst)
        return load().count
    }

    // MARK: Хранилище

    static func load() -> [DictationCorpusEntry] {
        guard let url = try? indexURL(),
              let data = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: "\n").compactMap {
            try? decoder.decode(DictationCorpusEntry.self,
                                from: Data($0.utf8))
        }
    }

    private static func append(_ entry: DictationCorpusEntry) {
        var all = load()
        all.append(entry)
        save(all)
    }

    private static func save(_ entries: [DictationCorpusEntry]) {
        guard let url = try? indexURL() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = entries.compactMap { entry -> String? in
            (try? encoder.encode(entry)).flatMap {
                String(data: $0, encoding: .utf8)
            }
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Потолки: лишние записи (старые первыми) удаляются вместе с аудио.
    private static func enforceCaps() {
        var all = load()
        guard let dir = try? directory() else { return }
        func audioSize() -> Int64 {
            all.compactMap(\.audioFile).reduce(Int64(0)) { sum, name in
                let path = dir.appendingPathComponent(name).path
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                return sum + ((attrs?[.size] as? Int64) ?? 0)
            }
        }
        while all.count > maxEntries
                || (audioSize() > maxAudioBytes && all.count > 1) {
            let removed = all.removeFirst()
            if let audio = removed.audioFile {
                try? FileManager.default.removeItem(
                    at: dir.appendingPathComponent(audio))
            }
        }
        save(all)
    }
}
