import Foundation

// ============================================================================
// Базы знаний Софи — парсер и детерминированная выборка (docs/kb_spec.md).
//
// Предустановленные чаты отвечают из курированных локальных баз, а не из
// весов модели. Выборка — без ML: префикс-матч ключей (≥4 символов),
// ранжирование по числу совпадений, бюджет ~1200 оценочных токенов,
// секция-ядро всегда, при нуле совпадений — ядро + «Оглавление».
// ============================================================================

nonisolated struct KBSection: Equatable, Sendable {
    let title: String
    let keys: [String]      // нижний регистр, основы слов; ["всегда"] = ядро
    let body: String

    var isCore: Bool { keys == ["всегда"] }
    var isTOC: Bool { title == "Оглавление" }
}

nonisolated struct KnowledgeBase: Sendable {
    let name: String        // из шапки «# База: <имя> …»
    let sections: [KBSection]

    /// Загрузка из бандла: Resources/sophie_kb/<file>.md
    static func load(file: String) throws -> KnowledgeBase {
        let url = Bundle.main.url(forResource: file, withExtension: "md",
                                  subdirectory: "sophie_kb")
            ?? Bundle.main.url(forResource: file, withExtension: "md")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw LLMError.generationFailed(reason: "база \(file).md не найдена в бандле")
        }
        return parse(text)
    }

    /// Разбор формата спеки: `# База: …`, секции `## …`,
    /// первая строка секции — `ключи: …`.
    static func parse(_ text: String) -> KnowledgeBase {
        var name = ""
        var sections: [KBSection] = []
        var title: String?
        var keys: [String] = []
        var body: [String] = []

        func flush() {
            if let t = title {
                sections.append(KBSection(
                    title: t, keys: keys,
                    body: body.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            keys = []; body = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") {
                name = line.dropFirst(2)
                    .replacingOccurrences(of: "База: ", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## ") {
                flush()
                title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("ключи:"), title != nil, keys.isEmpty, body.isEmpty {
                keys = line.dropFirst("ключи:".count)
                    .lowercased()
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if title != nil {
                body.append(String(line))
            }
        }
        flush()
        return KnowledgeBase(name: name, sections: sections)
    }
}

nonisolated enum KnowledgeRetriever {

    /// Бюджет знаний в оценочных токенах (символы/3), спека §Алгоритм.
    static let tokenBudget = 1200

    /// Совпадение ключа и слова (спека, п.2): ключ длиной ≥4 — префикс
    /// слова, или слово — префикс ключа. Короткие ключи (<4, например
    /// «sos») совпадают только целиком — иначе трёхбуквенный ключ ловил
    /// бы пол-языка.
    static func matches(key: String, word: String) -> Bool {
        if key == word { return true }
        if key.count >= 4 && word.hasPrefix(key) { return true }
        if word.count >= 4 && key.hasPrefix(word) { return true }
        return false
    }

    /// Детерминированная выборка секций под запрос. Возвращает секции
    /// в порядке: ядро, затем топ по числу совпадений (стабильно по
    /// порядку в файле), в пределах бюджета.
    static func select(from base: KnowledgeBase, query: String) -> [KBSection] {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        var picked: [KBSection] = base.sections.filter(\.isCore)   // ядро всегда

        // Ранжирование по числу совпавших ключей; при равенстве — порядок файла
        let scored: [(section: KBSection, score: Int, order: Int)] =
            base.sections.enumerated().compactMap { order, section in
                guard !section.isCore, !section.isTOC else { return nil }
                let score = section.keys.reduce(0) { sum, key in
                    sum + (words.contains { matches(key: key, word: $0) } ? 1 : 0)
                }
                return score > 0 ? (section, score, order) : nil
            }
            .sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }

        if scored.isEmpty {
            // Ноль совпадений → ядро + «Оглавление» (Софи говорит, о чём умеет)
            picked += base.sections.filter(\.isTOC)
            return picked
        }

        var used = picked.reduce(0) { $0 + estimatedTokens($1.body) }
        for candidate in scored {
            let cost = estimatedTokens(candidate.section.body)
            if used + cost > tokenBudget { break }
            used += cost
            picked.append(candidate.section)
        }
        return picked
    }

    /// Готовый текст выдержек для промпта.
    static func excerpt(from base: KnowledgeBase, query: String) -> String {
        select(from: base, query: query)
            .map { "### \($0.title)\n\($0.body)" }
            .joined(separator: "\n\n")
    }

    static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 3)
    }
}

// MARK: - Выборка через несколько баз (свободный чат)

extension KnowledgeRetriever {

    /// Свободный чат: запрос гоняется по ВСЕМ базам, топ-секции до общего
    /// бюджета. Ядра и оглавления не включаются (это атрибуты пресет-чатов);
    /// ноль совпадений → пусто (свободный чат отвечает без блока знаний).
    /// Стабильный порядок: очки ↓, затем порядок базы, затем порядок в файле.
    static func selectAcross(_ bases: [KnowledgeBase],
                             query: String) -> [KBSection] {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        let scored: [(section: KBSection, score: Int, baseIndex: Int, order: Int)] =
            bases.enumerated().flatMap { baseIndex, base in
                base.sections.enumerated().compactMap { order, section in
                    guard !section.isCore, !section.isTOC else { return nil }
                    let score = section.keys.reduce(0) { sum, key in
                        sum + (words.contains { matches(key: key, word: $0) } ? 1 : 0)
                    }
                    return score > 0 ? (section, score, baseIndex, order) : nil
                }
            }
            .sorted { ($0.score, -$0.baseIndex, -$0.order)
                    > ($1.score, -$1.baseIndex, -$1.order) }

        var picked: [KBSection] = []
        var used = 0
        for candidate in scored {
            let cost = estimatedTokens(candidate.section.body)
            if used + cost > tokenBudget { break }
            used += cost
            picked.append(candidate.section)
        }
        return picked
    }
}

// MARK: - Сборка блока знаний для промпта

/// Маршрутизация знаний: пресет-чат — только своя база (по kb_spec),
/// свободный чат — все базы приложения, без строгого «ТОЛЬКО по выдержкам»
/// (свободному чату база — источник фактов, а не клетка).
nonisolated enum SophieKnowledge {

    static let freeChatBlockHeader =
        "Выдержки из проверенных баз приложения — опирайся на них там, "
        + "где они отвечают на вопрос:"

    /// Пресет: ядро всегда, топ своей базы, ноль → ядро + оглавление.
    static func blockForPreset(_ preset: SophiePreset, query: String,
                               base: KnowledgeBase) -> String {
        let excerpts = KnowledgeRetriever.excerpt(from: base, query: query)
        return preset.promptBlock + "\n\n" + excerpts
    }

    /// Свободный чат: топ по всем базам; nil — совпадений нет.
    static func blockForFreeChat(query: String,
                                 bases: [KnowledgeBase]) -> String? {
        let sections = KnowledgeRetriever.selectAcross(bases, query: query)
        guard !sections.isEmpty else { return nil }
        let excerpts = sections
            .map { "### \($0.title)\n\($0.body)" }
            .joined(separator: "\n\n")
        return freeChatBlockHeader + "\n\n" + excerpts
    }
}

// MARK: - Предустановленные чаты (sophie_presence §2.1)

/// Четыре закреплённых чата по дизайну (design/sophie, «всегда под рукой»).
/// Не удаляются; историю можно очистить. У каждого — свой пак знаний.
nonisolated enum SophiePreset: String, CaseIterable, Identifiable, Sendable {
    // Порядок объявления = порядок в папке (задание 30.07):
    // SOS первым, красной иконкой — единственный красный в приложении.
    // rawValue не менялись — ключи хранения историй прежние.
    // project добавлен 06.08 (пак «О проекте») — после about по смыслу.
    case sos, firstAid, comms, about, project, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .about: "О приложении"
        case .comms: "Связь"
        case .firstAid: "Первая помощь"
        case .sos: "SOS"
        case .project: "О проекте"
        case .history: "История названия"
        }
    }

    var icon: String {
        switch self {
        case .about: "app.badge"
        case .comms: "antenna.radiowaves.left.and.right"
        case .firstAid: "cross.case"
        case .sos: "light.beacon.max"
        case .project: "signpost.right"
        case .history: "building.columns"
        }
    }

    /// Подзаголовки закреплённых чатов — формулировки мокапа sophie_folder.
    var subtitle: String {
        switch self {
        case .about: "что умеет \(AppIdentity.appName) и как работает без сети"
        // без слова «узел» — в интерфейсе его не употребляем
        case .comms: "как добить сигнал, ретрансляция"
        case .firstAid: "раны, переломы, тепловой удар"
        case .sos: "что делать до прихода помощи"
        case .project: "как устроено внутри и куда идём"
        case .history: "Клод Шапп, Софи и первая сеть"
        }
    }

    var kbFile: String {
        switch self {
        case .about: "kb_app_ru"
        case .comms: "kb_svyaz_ru"
        case .firstAid: "kb_first_aid_ru"
        case .sos: "kb_sos_ru"
        case .project: "kb_project_ru"
        case .history: "kb_history_ru"
        }
    }

    /// Блок промпта из kb_spec.md — дословно.
    static let kbPromptBlock = """
    Ниже — выдержки из проверенной базы этого чата. Отвечай ТОЛЬКО по ним \
    своими словами, кратко. Если ответа в выдержках нет — скажи прямо, что \
    в базе этого нет, и предложи темы из базы. Не добавляй фактов от себя.
    """

    /// Доп. строка для «Первой помощи» — дословно из спеки.
    static let firstAidCaution = """
    В конце ответа про травму/состояние одна короткая строка: это базовые \
    действия, не замена медицинской помощи; при серьёзных признаках — SOS.
    """

    var promptBlock: String {
        self == .firstAid
            ? Self.kbPromptBlock + "\n" + Self.firstAidCaution
            : Self.kbPromptBlock
    }
}
