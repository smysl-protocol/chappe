import Foundation

// ============================================================================
// Сборка промпта Софи (sophie_presence §1, фаза 1: окно без суммария).
//
// Промпт = системный промпт (Resources/prompts/sophie_system_ru.txt) +
// скользящее окно последних сообщений с бюджетом ~3000 токенов + новое
// сообщение. Системный промпт и стабильное начало истории образуют
// общий префикс — тёплый KV-кэш (LlamaRuntime) подхватывает его так же,
// как PIVOT-промпт.
// ============================================================================

nonisolated struct SophieMessage: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user, sophie

        /// Обратная совместимость: истории до переименования ассистента
        /// (30.07.2026) писали роль как "kaya" — читаем её как sophie.
        /// Неизвестная роль — ошибка, как и раньше (битую запись скипнет
        /// SafeHistoryDecoder, а не молча переврёт).
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "user": self = .user
            case "sophie", "kaya": self = .sophie
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "неизвестная роль: \(raw)"))
            }
        }
    }
    let id: UUID
    let role: Role
    var text: String
    let date: Date
    /// Ответ оборван кнопкой «стоп» (маркер «остановлено вами» в пузыре).
    /// Optional — старые истории без поля читаются как nil (= false).
    var stopped: Bool?
    /// Карточка состояния сети (WP3 02.08): текст собран кодом, не
    /// моделью; UI рендерит её карточкой. Optional — обратная
    /// совместимость историй.
    var statusCard: Bool?

    init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.date = Date()
        self.stopped = nil
        self.statusCard = nil
    }

    var isStopped: Bool { stopped == true }
    var isStatusCard: Bool { statusCard == true }
}

nonisolated enum SophiePrompt {

    /// Бюджет окна истории, в оценочных токенах (sophie_presence §1:
    /// реалистичный контекст на устройстве 4–8k, берём нижнюю половину
    /// под историю, остальное — системный промпт и ответ).
    static let tokenBudget = 3000

    /// Грубая оценка токенов без токенизатора: ~3 символа на токен
    /// для русского текста. Точность не нужна — это потолок окна,
    /// жёсткую границу держит контекст модели.
    static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 3)
    }

    /// Системный промпт Софи из бандла (не хардкод — файл правится
    /// без перекомпиляции логики).
    static func systemPrompt() throws -> String {
        let url = Bundle.main.url(forResource: "sophie_system_ru", withExtension: "txt",
                                  subdirectory: "prompts")
            ?? Bundle.main.url(forResource: "sophie_system_ru", withExtension: "txt")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw LLMError.generationFailed(reason: "prompts/sophie_system_ru.txt нет в бандле")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Скользящее окно: самые свежие сообщения, суммарно не больше
    /// бюджета. Старшее отбрасывается целиком (без обрезки посередине).
    static func window(_ history: [SophieMessage],
                       budget: Int = tokenBudget) -> [SophieMessage] {
        var used = 0
        var picked: [SophieMessage] = []
        for message in history.reversed() {
            let cost = estimatedTokens(message.text) + 8   // +8 на разметку роли
            if used + cost > budget { break }
            used += cost
            picked.append(message)
        }
        return picked.reversed()
    }

    /// Текст user-части промпта: суммарий свёрнутой истории (если есть)
    /// + расшифровка окна + (для пресет-чатов) блок знаний с выдержками
    /// + новое сообщение. Суммарий идёт ПЕРВЫМ: меняется реже всего,
    /// префикс для тёплого KV-кэша ломается только при новой свёртке.
    /// Блок знаний идёт ПОСЛЕ истории: выдержки меняются от запроса
    /// к запросу.
    static func userPrompt(window: [SophieMessage], newText: String,
                           knowledgeBlock: String? = nil,
                           summary: String? = nil,
                           clockLine: String? = nil) -> String {
        var lines: [String] = []
        if let summary, !summary.isEmpty {
            lines.append("Суммарий более раннего разговора (факты, "
                       + "сжато): " + summary)
        }
        for message in window {
            lines.append((message.role == .user ? "Пользователь: " : "\(AppIdentity.assistantName): ")
                         + message.text)
        }
        if let knowledgeBlock {
            lines.append(knowledgeBlock)
        }
        // Данные устройства (Ф6) — в хвосте, у нового сообщения:
        // меняются каждый ход и не должны ломать тёплый префикс KV
        if let clockLine {
            lines.append(clockLine)
        }
        lines.append("Пользователь: " + newText)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Хранилище чата

/// Запись в папке чатов Софи (sophie_presence §2, мокап sophie_folder):
/// свои чаты создаются/переименовываются/удаляются; пресеты — отдельно.
nonisolated struct SophieChatInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String            // ключ хранения истории и суммария
    var title: String
    var createdAt: Date
    /// Закреплён пользователем в верхней папке (рядом с пресетами).
    /// Optional — старые списки без поля читаются как nil (= false).
    var pinned: Bool?

    init(title: String) {
        self.id = "user_" + UUID().uuidString
        self.title = title
        self.createdAt = Date()
        self.pinned = nil
    }

    init(id: String, title: String, createdAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.pinned = nil
    }

    var isPinned: Bool { pinned == true }
}

/// История чата — JSON-файл в Application Support, как llm_config.json:
/// единственный формат локального хранения, который уже есть в приложении.
nonisolated enum SophieChatStore {

    /// key: "chat" — свободный чат; "chat_about" и т.п. — пресеты.
    static func chatURL(key: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Sophie", isDirectory: true)
        // Миграция после переименования ассистента (30.07.2026): истории
        // старых сборок лежали в каталоге «Kaya» — переносим целиком,
        // чтобы разговоры не пропали. Одноразово: после переноса старого
        // каталога больше нет.
        let legacy = base.appendingPathComponent("Kaya", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(key).json")
    }

    static func load(key: String) -> [SophieMessage] {
        guard let url = try? chatURL(key: key),
              let data = try? Data(contentsOf: url) else { return [] }
        // Правило хранилищ (28.07): битые записи скипаются, целиком
        // нечитаемый файл — в карантин, историю не пересоздаём молча
        guard let messages = SafeHistoryDecoder.decodeArray(
            SophieMessage.self, from: data, label: key) else {
            SafeHistoryDecoder.quarantine(url)
            return []
        }
        return messages
    }

    static func save(_ messages: [SophieMessage], key: String) {
        guard let url = try? chatURL(key: key) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(messages).write(to: url, options: .atomic)
    }

    // MARK: Папка чатов (sophie_presence §2)

    static func chatListURL() throws -> URL {
        try chatURL(key: "chat_list")
    }

    /// Список своих чатов. Миграция: старый одиночный «Свободный чат»
    /// (ключ "chat") с непустой историей попадает в папку первой записью.
    static func loadChatList() -> [SophieChatInfo] {
        if let url = try? chatListURL(),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([SophieChatInfo].self, from: data) {
            return list
        }
        if !load(key: "chat").isEmpty {
            let legacy = SophieChatInfo(id: "chat", title: "Свободный чат",
                                      createdAt: Date())
            saveChatList([legacy])
            return [legacy]
        }
        return []
    }

    static func saveChatList(_ list: [SophieChatInfo]) {
        guard let url = try? chatListURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(list).write(to: url, options: .atomic)
    }

    /// Удалить чат целиком: история + суммарий (запись из списка
    /// вычёркивает вызывающий).
    static func deleteChat(key: String) {
        if let url = try? chatURL(key: key) {
            try? FileManager.default.removeItem(at: url)
        }
        deleteSummary(key: key)
    }

    // MARK: Суммарий чата (sophie_presence §1, фоновая свёртка P3)

    /// Состояние свёртки: абзац фактов + курсор — сколько сообщений
    /// истории уже свёрнуто (прерываемость: продолжаем с курсора).
    struct SummaryState: Codable, Equatable, Sendable {
        var text: String = ""
        var cursor: Int = 0
    }

    static func summaryURL(key: String) throws -> URL {
        try chatURL(key: key + "_summary")
    }

    static func loadSummary(key: String) -> SummaryState {
        guard let url = try? summaryURL(key: key),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SummaryState.self, from: data)
        else { return SummaryState() }
        return state
    }

    static func saveSummary(_ state: SummaryState, key: String) {
        guard let url = try? summaryURL(key: key) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(state).write(to: url, options: .atomic)
    }

    static func deleteSummary(key: String) {
        if let url = try? summaryURL(key: key) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
