import Foundation
import Network
import CryptoKit
import Combine

// ============================================================================
// Загрузка модели ИЗ ПРИЛОЖЕНИЯ (Ф1.1, бриф 31.07) — путь для живых
// людей; импорт через Files остаётся запасным.
//
// - URL, SHA-256 и размер — в конфиге (Resources/model_download.json,
//   поверх — Application Support/model_download.json), не в коде.
//   Хеш и размер сверены с эталонным файлом проекта (shasum 30.07:
//   2fde00ce…, 2 497 280 736 байт; CDN отдаёт тот же размер).
// - Докачка при обрыве: resumeData сохраняется на диск и переживает
//   перезапуск приложения (сервер отдаёт Accept-Ranges: bytes).
// - По умолчанию только Wi-Fi; по сотовой — только явным действием.
// - После загрузки — проверка SHA-256 (потоково, вне главного потока);
//   расхождение = файл повреждён, честная ошибка и удаление.
// - Хранение: Application Support/Models, исключено из iCloud-бэкапа.
// ============================================================================

/// Что качать: описание из конфига.
nonisolated struct ModelDownloadSpec: Codable, Sendable, Equatable {
    var displayName: String
    var modelFile: String
    var url: String
    var sha256: String
    var sizeBytes: Int64

    /// Application Support/model_download.json → бандл → nil.
    static func load() -> ModelDownloadSpec? {
        if let dir = try? LLMModelConfig.modelsDirectory() {
            let override = dir.deletingLastPathComponent()
                .appendingPathComponent("model_download.json")
            if let data = try? Data(contentsOf: override),
               let spec = try? JSONDecoder().decode(ModelDownloadSpec.self,
                                                    from: data) {
                return spec
            }
        }
        guard let url = Bundle.main.url(forResource: "model_download",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelDownloadSpec.self, from: data)
    }

    var sizeText: String {
        String(format: "%.1f ГБ", Double(sizeBytes) / 1_000_000_000)
    }
}

@MainActor
final class ModelDownloader: NSObject, ObservableObject {

    static let shared = ModelDownloader()

    enum State: Equatable {
        case idle
        /// Есть сохранённая докачка (обрыв или отмена) — можно продолжить.
        case paused(reason: String)
        case downloading(fraction: Double, bytes: Int64, total: Int64)
        case verifying
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Загрузка идёт по сотовой (пользователь явно разрешил).
    private(set) var cellularAllowed = false

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var spec: ModelDownloadSpec?

    // MARK: Состояние при старте

    /// Восстановить видимое состояние: установлена / есть докачка / чисто.
    func refresh(spec: ModelDownloadSpec?) {
        self.spec = spec
        guard let spec else { return }
        if Self.isInstalled(spec: spec) {
            state = .installed
        } else if (try? resumeDataURL(spec).checkResourceIsReachable()) == true {
            state = .paused(reason: "загрузка прервана — можно продолжить")
        } else if case .downloading = state {
            // уже качается — не трогаем
        } else {
            state = .idle
        }
    }

    nonisolated static func isInstalled(spec: ModelDownloadSpec) -> Bool {
        guard let dir = try? LLMModelConfig.modelsDirectory() else { return false }
        let url = dir.appendingPathComponent(spec.modelFile)
        return FileManager.default.fileExists(atPath: url.path)
            && ModelStore.fileSize(url) == spec.sizeBytes
    }

    /// Сейчас телефон на Wi-Fi? (для честного предупреждения ДО загрузки)
    static func onWiFi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning:
                    path.usesInterfaceType(.wifi)
                    || path.usesInterfaceType(.wiredEthernet))
            }
            monitor.start(queue: .global())
        }
    }

    // MARK: Загрузка

    /// Старт (или продолжение сохранённой докачки).
    /// allowCellular — только явным действием пользователя.
    func start(allowCellular: Bool = false) {
        guard let spec else {
            state = .failed("нет конфига загрузки (model_download.json)")
            return
        }
        guard let url = URL(string: spec.url) else {
            state = .failed("кривой URL в конфиге загрузки")
            return
        }
        cellularAllowed = allowCellular

        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = allowCellular
        // без лимита ожидания всего файла: 2.4 ГБ на медленной сети — часы
        config.timeoutIntervalForResource = 24 * 3600
        let session = URLSession(configuration: config,
                                 delegate: self, delegateQueue: nil)
        self.session = session

        if let data = try? Data(contentsOf: resumeDataURL(spec)),
           !data.isEmpty {
            // докачка с места обрыва
            try? FileManager.default.removeItem(at: resumeDataURL(spec))
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
        }
        state = .downloading(fraction: 0, bytes: 0, total: spec.sizeBytes)
        task?.resume()
    }

    /// Отмена с сохранением докачки: продолжить можно в любой момент.
    func cancel() {
        guard let task, let spec else { return }
        task.cancel { [weak self] resumeData in
            Task { @MainActor in
                guard let self else { return }
                if let resumeData {
                    try? resumeData.write(to: self.resumeDataURL(spec),
                                          options: .atomic)
                    self.state = .paused(reason: "остановлено вами — "
                                       + "продолжится с этого же места")
                } else {
                    self.state = .idle
                }
            }
        }
        self.task = nil
    }

    private nonisolated func resumeDataURL(_ spec: ModelDownloadSpec) -> URL {
        let dir = (try? LLMModelConfig.modelsDirectory())
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(spec.modelFile + ".resume")
    }

    // MARK: Проверка и установка (после скачивания)

    private func verifyAndInstall(temp: URL) {
        guard let spec else { return }
        state = .verifying
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Потоковый SHA-256: 2.4 ГБ не влезают в память целиком
                let digest = try Self.sha256Hex(of: temp)
                guard digest == spec.sha256.lowercased() else {
                    try? FileManager.default.removeItem(at: temp)
                    await self?.finish(.failed(
                        "файл повреждён при передаче (SHA-256 не совпал) — "
                        + "скачайте заново"))
                    return
                }
                let dir = try LLMModelConfig.modelsDirectory()
                let dest = dir.appendingPathComponent(spec.modelFile)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                try ModelStore.excludeFromBackup(dest)

                // Включить помощника: локальный конфиг с этим файлом
                var config = LLMModelConfig.localQwen
                config.modelFile = spec.modelFile
                config.displayName = spec.displayName
                try config.saveAsActive()
                await ModelScheduler.shared.invalidateProvider()
                await self?.finish(.installed)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                await self?.finish(.failed("установка не удалась: "
                                           + error.localizedDescription))
            }
        }
    }

    private func finish(_ state: State) {
        self.state = state
    }

    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024),
              !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Делегат URLSession

extension ModelDownloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite : 1
        let fraction = Double(totalBytesWritten) / Double(total)
        Task { @MainActor in
            self.state = .downloading(fraction: fraction,
                                      bytes: totalBytesWritten,
                                      total: total)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // location живёт только до конца колбэка — забираем сразу
        let holding = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-download-\(UUID().uuidString).tmp")
        try? FileManager.default.moveItem(at: location, to: holding)
        Task { @MainActor in
            self.verifyAndInstall(temp: holding)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }   // успех пришёл в didFinishDownloading
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData]
            as? Data
        Task { @MainActor in
            guard let spec = self.spec else { return }
            if (error as? URLError)?.code == .cancelled,
               case .paused = self.state {
                return   // отмена руками уже оформлена в cancel()
            }
            if let resumeData {
                // обрыв сети: докачка сохранена, продолжение — кнопкой
                try? resumeData.write(to: self.resumeDataURL(spec),
                                      options: .atomic)
                self.state = .paused(reason: "связь оборвалась — загрузка "
                    + "продолжится с этого же места")
            } else {
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}
