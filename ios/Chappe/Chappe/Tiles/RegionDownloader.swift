import Foundation
import Combine
import CoreLocation
import MapLibre
import Network

// ============================================================================
// Реализация MapTileStore поверх штатных offline packs MapLibre (ADR 003).
//
// Метаданные региона (имя, bbox, зумы, версия стиля) живут в context
// самого pack'а (Data с JSON) — отдельного каталога нет: pack и есть
// источник истины, состояние не может разъехаться с содержимым базы.
//
// Скачивание только по интернету — pack качает с тайл-сервера конфига.
// Пауза/возобновление/прогресс — штатные (suspend/resume/notification).
// ============================================================================

@MainActor
final class RegionDownloader: NSObject, ObservableObject, MapTileStore {

    static let shared = RegionDownloader()

    @Published private(set) var regions: [MapRegion] = []

    /// Метаданные, зашитые в context pack'а.
    nonisolated private struct PackContext: Codable {
        let id: String
        var name: String
        var bbox: RegionBBox
        var minZoom: Int
        var maxZoom: Int
        var styleVersion: String
        var createdAt: Date
    }

    nonisolated enum DownloadError: Error, LocalizedError {
        case diskBudget(needBytes: Int64, freeBytes: Int64)
        case packCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .diskBudget(let need, let free):
                "не хватает места: нужно ~\(need / 1_000_000) МБ, свободно \(free / 1_000_000) МБ (порог \(MapConfig.minFreeDiskBytes / 1_000_000) МБ)"
            case .packCreationFailed(let reason):
                "не удалось начать скачивание: \(reason)"
            }
        }
    }

    /// KVO на MLNOfflineStorage.packs: свойство грузится из базы
    /// АСИНХРОННО после запуска (док MLNOfflineStorage.h: «observe KVO
    /// change notifications on the packs key path»). Без этого regions
    /// после холодного старта оставался пуст — скачанные регионы
    /// «пропадали» до первого события прогресса, и баннер «Офлайн-карт
    /// ещё нет» висел поверх реально скачанных карт (баг Ф4, 30.07).
    private var packsObservation: NSKeyValueObservation?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(packProgressChanged(_:)),
            name: NSNotification.Name.MLNOfflinePackProgressChanged,
            object: nil)
        packsObservation = MLNOfflineStorage.shared.observe(
            \.packs, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.reloadRegions() }
        }
        Self.excludeTileDatabaseFromBackup()
        reloadRegions()
        // Ф2.4: возврат сети → продолжить оборванные загрузки сами
        // (ручные паузы не трогаем — их различает manuallyPaused)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.resumeInterruptedDownloads() }
        }
        networkMonitor.start(queue: .global(qos: .utility))
    }

    private let networkMonitor = NWPathMonitor()

    /// Паузы, поставленные РУКАМИ (кнопка «Пауза») — их автопродолжение
    /// не трогает. Обрыв сети/перезапуск приложения дают то же
    /// состояние inactive у пака — различаем только по этому списку.
    private var manuallyPausedIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(
                forKey: "map.manuallyPaused") ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue),
                                      forKey: "map.manuallyPaused")
        }
    }

    /// Продолжить все НЕ ручные паузы (Ф2.4). Вызывается при возврате
    /// сети и при открытии экрана регионов.
    func resumeInterruptedDownloads() {
        reloadRegions()
        let manual = manuallyPausedIDs
        for region in regions {
            if case .paused = region.state, !manual.contains(region.id) {
                pack(for: region.id)?.resume()
            }
        }
        reloadRegions()
    }

    /// Тайлы — не пользовательские данные, а кэш весом в десятки МБ:
    /// из iCloud-бэкапа исключаются (п.6 плана 29.07). Регион всегда
    /// можно перекачать при интернете.
    nonisolated private static func excludeTileDatabaseFromBackup() {
        var url = MLNOfflineStorage.shared.databaseURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: MapTileStore

    var styleURL: URL { MapConfig.styleURL }

    func estimatedSizeBytes(bbox: RegionBBox, minZoom: Int, maxZoom: Int) -> Int64 {
        Int64(TileMath.tileCount(bbox: bbox, minZoom: minZoom, maxZoom: maxZoom))
            * MapConfig.estimatedTileBytes
    }

    func startDownload(name: String, bbox: RegionBBox,
                       minZoom: Int, maxZoom: Int) throws {
        // Дисковый бюджет — предупреждение ДО начала скачивания
        let need = estimatedSizeBytes(bbox: bbox, minZoom: minZoom, maxZoom: maxZoom)
        let free = Self.freeDiskBytes()
        guard free - need > MapConfig.minFreeDiskBytes else {
            throw DownloadError.diskBudget(needBytes: need, freeBytes: free)
        }

        let context = PackContext(id: UUID().uuidString, name: name,
                                  bbox: bbox, minZoom: minZoom, maxZoom: maxZoom,
                                  styleVersion: MapConfig.styleVersion,
                                  createdAt: Date())
        guard let contextData = try? JSONEncoder().encode(context) else {
            throw DownloadError.packCreationFailed("не закодировался context")
        }

        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: bbox.minLat, longitude: bbox.minLon),
            ne: CLLocationCoordinate2D(latitude: bbox.maxLat, longitude: bbox.maxLon))
        let region = MLNTilePyramidOfflineRegion(
            styleURL: styleURL, bounds: bounds,
            fromZoomLevel: Double(minZoom), toZoomLevel: Double(maxZoom))

        MLNOfflineStorage.shared.addPack(for: region,
                                         withContext: contextData) { [weak self] pack, error in
            Task { @MainActor in
                if let pack {
                    pack.resume()
                } else {
                    // Ошибку старта видно в состоянии региона; лог по-русски
                    print("Регион «\(name)»: старт не удался: \(error?.localizedDescription ?? "?")")
                }
                self?.reloadRegions()
            }
        }
    }

    func pauseDownload(id: String) {
        pack(for: id)?.suspend()
        manuallyPausedIDs.insert(id)   // ручная пауза — автозапуск не трогает
        reloadRegions()
    }

    func resumeDownload(id: String) {
        pack(for: id)?.resume()
        manuallyPausedIDs.remove(id)
        reloadRegions()
    }

    func deleteRegion(id: String) {
        guard let pack = pack(for: id) else { return }
        MLNOfflineStorage.shared.removePack(pack) { [weak self] _ in
            Task { @MainActor in self?.reloadRegions() }
        }
    }

    func coverage() -> CoverageIndex {
        CoverageIndex(regions: regions)
    }

    // MARK: Внутреннее

    private func pack(for id: String) -> MLNOfflinePack? {
        MLNOfflineStorage.shared.packs?.first {
            (try? JSONDecoder().decode(PackContext.self, from: $0.context))?.id == id
        }
    }

    /// Пересобирает [MapRegion] из фактических packs — единственный
    /// источник истины, каталога-двойника нет.
    func reloadRegions() {
        let packs = MLNOfflineStorage.shared.packs ?? []
        regions = packs.compactMap { pack in
            guard let ctx = try? JSONDecoder().decode(PackContext.self,
                                                      from: pack.context) else {
                return nil   // чужой/битый pack — не наш регион
            }
            let progress = pack.progress
            let expected = max(progress.countOfResourcesExpected, 1)
            let fraction = min(1.0, Double(progress.countOfResourcesCompleted)
                                    / Double(expected))
            let state: RegionState
            switch pack.state {
            case .complete:
                state = ctx.styleVersion == MapConfig.styleVersion ? .ready : .stale
            case .active:
                state = .downloading(progress: fraction)
            case .inactive, .unknown:
                // resources может быть 0/0 до первого прогресса
                state = fraction >= 1.0 ? .ready : .paused(progress: fraction)
            case .invalid:
                state = .none
            @unknown default:
                state = .none
            }
            return MapRegion(id: ctx.id, name: ctx.name, bbox: ctx.bbox,
                             minZoom: ctx.minZoom, maxZoom: ctx.maxZoom,
                             sizeBytes: Int64(progress.countOfBytesCompleted),
                             downloadedAt: ctx.createdAt,
                             styleVersion: ctx.styleVersion,
                             state: state)
        }
    }

    @objc private func packProgressChanged(_ note: Notification) {
        Task { @MainActor in self.reloadRegions() }
    }

    nonisolated static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
