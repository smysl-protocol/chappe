import Foundation

// ============================================================================
// Абстракция тайлового стека (WP2, ADR 003).
//
// Экран карты и модель данных не знают, что внутри — offline packs
// MapLibre, PMTiles или что-то третье: они видят только этот протокол
// и модель MapRegion. Смена стека = смена реализации, не экрана.
// ============================================================================

// MARK: - Модель региона

/// Прямоугольник региона. Отдельный тип, чтобы не таскать четвёрки чисел.
nonisolated struct RegionBBox: Codable, Hashable, Sendable {
    let minLat: Double
    let minLon: Double
    let maxLat: Double
    let maxLon: Double

    func contains(lat: Double, lon: Double) -> Bool {
        lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
    }
}

/// Состояние регионального пакета.
nonisolated enum RegionState: Codable, Hashable, Sendable {
    case none                       // не скачан
    case downloading(progress: Double)   // 0…1
    case paused(progress: Double)
    case ready
    case stale                      // стиль обновился, тайлы старые
}

/// Региональный пакет карты. Скачивается ТОЛЬКО по интернету:
/// по мешу тайлы не поедут никогда (регион — десятки МБ, канал — сотни байт).
nonisolated struct MapRegion: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var bbox: RegionBBox
    var minZoom: Int
    var maxZoom: Int
    var sizeBytes: Int64?
    var downloadedAt: Date?
    var styleVersion: String?
    var state: RegionState
}

// MARK: - Протокол стека

/// Всё, что экранам позволено знать о тайлах.
@MainActor
protocol MapTileStore: AnyObject {
    /// URL стиля для рендера (тёмный, из конфига).
    var styleURL: URL { get }

    /// Известные регионы с их состоянием.
    var regions: [MapRegion] { get }

    /// Оценка веса ДО начала скачивания, байт.
    func estimatedSizeBytes(bbox: RegionBBox, minZoom: Int, maxZoom: Int) -> Int64

    /// Старт скачивания. Бросает при нехватке диска (дисковый бюджет).
    func startDownload(name: String, bbox: RegionBBox,
                       minZoom: Int, maxZoom: Int) throws

    func pauseDownload(id: String)
    func resumeDownload(id: String)
    func deleteRegion(id: String)

    /// Быстрый ответ «есть ли тайлы в этой точке» — для серых зон и Софи.
    func coverage() -> CoverageIndex
}

// MARK: - Индекс покрытия

/// Иммутабельный снимок покрытия: точка → регион. Считается по bbox
/// готовых регионов — дёшево и детерминированно.
nonisolated struct CoverageIndex: Sendable {
    private let readyRegions: [(id: String, name: String, bbox: RegionBBox)]

    init(regions: [MapRegion]) {
        readyRegions = regions
            .filter { $0.state == .ready || $0.state == .stale }
            .map { ($0.id, $0.name, $0.bbox) }
    }

    /// Имя региона, покрывающего точку; nil — тайлов нет (серая зона).
    func regionName(lat: Double, lon: Double) -> String? {
        readyRegions.first { $0.bbox.contains(lat: lat, lon: lon) }?.name
    }

    func isCovered(lat: Double, lon: Double) -> Bool {
        regionName(lat: lat, lon: lon) != nil
    }
}

// MARK: - Слиппи-математика

/// Подсчёт тайлов по bbox и зумам — основа оценки веса до скачивания.
/// Стандартная XYZ-сетка Web Mercator (слиппи): проверяется тестами
/// на известных значениях.
nonisolated enum TileMath {

    /// Номер тайла X для долготы на зуме z.
    static func tileX(lon: Double, zoom: Int) -> Int {
        let n = pow(2.0, Double(zoom))
        let x = Int(floor((lon + 180.0) / 360.0 * n))
        return min(max(x, 0), Int(n) - 1)
    }

    /// Номер тайла Y для широты на зуме z (Web Mercator, широта ±85.05°).
    static func tileY(lat: Double, zoom: Int) -> Int {
        let clamped = min(max(lat, -85.05112878), 85.05112878)
        let n = pow(2.0, Double(zoom))
        let latRad = clamped * .pi / 180
        let y = Int(floor((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n))
        return min(max(y, 0), Int(n) - 1)
    }

    /// Число тайлов, покрывающих bbox на одном зуме.
    static func tileCount(bbox: RegionBBox, zoom: Int) -> Int {
        let x1 = tileX(lon: bbox.minLon, zoom: zoom)
        let x2 = tileX(lon: bbox.maxLon, zoom: zoom)
        let y1 = tileY(lat: bbox.maxLat, zoom: zoom)   // y растёт к югу
        let y2 = tileY(lat: bbox.minLat, zoom: zoom)
        return (x2 - x1 + 1) * (y2 - y1 + 1)
    }

    /// Сумма тайлов по диапазону зумов.
    static func tileCount(bbox: RegionBBox, minZoom: Int, maxZoom: Int) -> Int {
        guard minZoom <= maxZoom else { return 0 }
        return (minZoom...maxZoom).reduce(0) { $0 + tileCount(bbox: bbox, zoom: $1) }
    }
}
