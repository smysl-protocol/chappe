import Foundation

// ============================================================================
// Хранилище файлов моделей на устройстве (план llama_swift_plan.md §1).
//
// Правила:
//  - модели живут в Application Support/Models (создаёт LLMModelConfig);
//  - каждый файл исключается из iCloud-бэкапа (isExcludedFromBackup) —
//    нельзя заливать гигабайты весов в бэкап людям;
//  - импорт: копирование из выбранного в Files файла (dev-меню, фаза 1);
//    прод-загрузчик с SHA256 и докачкой — фаза 3, здесь его нет.
// ============================================================================

nonisolated enum ModelStore {

    /// Список GGUF-файлов в каталоге моделей.
    static func installedModels() -> [URL] {
        guard let dir = try? LLMModelConfig.modelsDirectory(),
              let items = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        return items.filter { $0.pathExtension.lowercased() == "gguf" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Импортирует файл модели (из Files/UIDocumentPicker) в каталог моделей.
    /// Возвращает конечный URL. Существующий файл с тем же именем заменяется.
    @discardableResult
    static func importModel(from source: URL) throws -> URL {
        let dir = try LLMModelConfig.modelsDirectory()
        let dest = dir.appendingPathComponent(source.lastPathComponent)

        // Доступ к файлу за пределами песочницы (выбран в Files)
        let secured = source.startAccessingSecurityScopedResource()
        defer { if secured { source.stopAccessingSecurityScopedResource() } }

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        try excludeFromBackup(dest)
        return dest
    }

    /// Импорт с NSFileCoordinator (Ф1.2, 31.07): файл, выбранный в
    /// Files, может лежать в iCloud НЕ скачанным — прямой copyItem на
    /// такой заглушке падает («couldn’t be opened»). Координированное
    /// чтение сперва докачивает файл. Вызывать ВНЕ главного потока:
    /// копирование 2.4 ГБ синхронно и занимает десятки секунд — на
    /// главном потоке это зависший интерфейс (причина «не сработало»).
    @discardableResult
    static func importModelCoordinated(from source: URL) throws -> URL {
        let dir = try LLMModelConfig.modelsDirectory()
        let dest = dir.appendingPathComponent(source.lastPathComponent)

        let secured = source.startAccessingSecurityScopedResource()
        defer { if secured { source.stopAccessingSecurityScopedResource() } }

        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: source, options: [],
            error: &coordinatorError) { readableURL in
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: readableURL, to: dest)
                try excludeFromBackup(dest)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return dest
    }

    static func deleteModel(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Подхватывает GGUF-файлы, закинутые в Documents приложения снаружи
    /// (Finder → вкладка Файлы, AirDrop или devicectl copy to), и переносит
    /// их в каталог моделей. Documents у нас виден в Files
    /// (UIFileSharingEnabled) — это входной лоток, жить модели там не должны.
    static func adoptDocumentsModels() {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first,
              let items = try? FileManager.default.contentsOfDirectory(
                  at: docs, includingPropertiesForKeys: nil),
              let dir = try? LLMModelConfig.modelsDirectory() else { return }
        for item in items where item.pathExtension.lowercased() == "gguf" {
            let dest = dir.appendingPathComponent(item.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            // Перенос, не копия: файл на том же томе, это мгновенно и без
            // удвоения места (веса бывают по 2.5 ГБ)
            if (try? FileManager.default.moveItem(at: item, to: dest)) != nil {
                try? excludeFromBackup(dest)
            }
        }
    }

    /// Размер файла в байтах (для экрана).
    static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }

    /// Исключить из iCloud-бэкапа — обязательное правило хранения весов.
    static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}
