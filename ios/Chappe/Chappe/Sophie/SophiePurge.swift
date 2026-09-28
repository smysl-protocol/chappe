import Foundation

// ============================================================================
// Стирание всех следов Софи для «Начать заново» (находка 21.08: freshStart
// не трогал каталог Sophie — истории, список чатов, суммарии и лог подмен
// дат переживали полный сброс личности).
//
// Слой стирания принимает корни явно: тест описывает свой мир (temp),
// боевой вызов purgeAll() подставляет настоящие. Глобального override у
// SophieChatStore нет намеренно — он переключал бы хранилище под
// параллельными тестами (та же грабля, из-за которой freshStart в сюите
// звать нельзя).
// ============================================================================

nonisolated enum SophiePurge {

    /// Боевой вызов из AppReset.freshStart() (проводка — зона app-сессии).
    static func purgeAll() {
        let fm = FileManager.default
        let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: false)
        let documents = fm.urls(for: .documentDirectory,
                                in: .userDomainMask).first
        purge(applicationSupport: appSupport, documents: documents)
    }

    /// Слой стирания с явными корнями.
    ///
    /// Веса GGUF и llm_config.json намеренно не трогаются (не личный след,
    /// перекачивать 2.4 ГБ дорого) — вердикт владельца может расширить.
    static func purge(applicationSupport: URL?, documents: URL?) {
        // Криптостирание памяти (шаг 3, решение владельца 21.08): ключ
        // в Keychain переживает снос приложения — рубится именно здесь.
        // Файл memory.enc уходит вместе с каталогом Sophie ниже; без
        // ключа любые уцелевшие копии файла — шум.
        SophieMemoryKey.destroy()
        let fm = FileManager.default
        if let appSupport = applicationSupport {
            // Истории всех чатов, chat_list.json, суммарии — целиком
            try? fm.removeItem(at: appSupport
                .appendingPathComponent("Sophie", isDirectory: true))
            // Легаси-каталог: миграция Kaya→Sophie в chatURL воскресила бы
            // стёртые разговоры при первом обращении новой личности
            try? fm.removeItem(at: appSupport
                .appendingPathComponent("Kaya", isDirectory: true))
        }
        if let documents {
            // Лог подмен дат: File Sharing, внутри фразы из разговоров
            try? fm.removeItem(at: documents
                .appendingPathComponent("date_gate_log.txt"))
        }
    }
}
