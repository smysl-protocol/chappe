import Foundation

// ============================================================================
// Конфиг слоя карты (п.6 плана 29.07: источник тайлов — в конфиге, не в
// коде). Тот же принцип, что llm_config.json: поведение меняется файлом
// `Application Support/map_config.json`, без правки кода. Поверх файла —
// UserDefaults-переопределения для dev-экспериментов. Приоритет:
// UserDefaults → map_config.json → зашитый дефолт.
//
// Шаблон файла (все поля опциональны):
// {
//   "styleURL": "https://tiles.openfreemap.org/styles/dark",
//   "styleVersion": "openfreemap-dark-2026-07",
//   "estimatedTileBytes": 45000,
//   "minFreeDiskBytes": 500000000,
//   "maxBeaconsPerHour": 6,
//   "beaconSuppressUtil": 0.5
// }
// ============================================================================

/// Содержимое map_config.json. Все поля опциональны — отсутствующее
/// берётся из дефолта.
nonisolated struct MapConfigFile: Codable {
    var styleURL: String?
    var styleVersion: String?
    var estimatedTileBytes: Int64?
    var minFreeDiskBytes: Int64?
    var maxBeaconsPerHour: Int?
    var beaconSuppressUtil: Double?
    var maxPackBytes: Int64?
    var warnPackBytes: Int64?
}

nonisolated enum MapConfig {

    /// Файл читается один раз на запуск: конфиг — не живая настройка.
    static let file: MapConfigFile = loadFile()

    static func fileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("map_config.json")
    }

    private static func loadFile() -> MapConfigFile {
        guard let url = try? fileURL(),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(MapConfigFile.self,
                                                     from: data) else {
            return MapConfigFile()
        }
        return parsed
    }

    // MARK: Тайлы

    /// Режим стиля карты (Ф3.2, бриф 31.07): «dark» / «light».
    /// САНКЦИОНИРОВАННОЕ исключение из правила единой тёмной темы:
    /// касается ТОЛЬКО карты (её смотрят на солнце), остальной
    /// интерфейс не меняется. Выбор запоминается.
    static var styleMode: String {
        get {
            UserDefaults.standard.string(forKey: "map.styleMode") ?? "dark"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "map.styleMode")
        }
    }

    /// Стиль карты — бандл-JSON с поднятым контрастом (Ф3.1, сборка
    /// tools/map/build_map_styles.py; база — стили OpenFreeMap, ADR 003).
    /// Тайлы/шрифты/спрайты в стиле остаются на openfreemap — векторные
    /// ДАННЫЕ общие для обоих режимов. Приоритет: UserDefaults →
    /// map_config.json (self-hosting) → бандл по режиму.
    static var styleURL: URL {
        if let s = UserDefaults.standard.string(forKey: "map.styleURL"),
           let url = URL(string: s) {
            return url
        }
        if let s = file.styleURL, let url = URL(string: s) {
            return url
        }
        let name = styleMode == "light" ? "style_light" : "style_dark"
        if let url = Bundle.main.url(forResource: name,
                                     withExtension: "json",
                                     subdirectory: "map_styles")
            ?? Bundle.main.url(forResource: name, withExtension: "json") {
            return url
        }
        return URL(string: "https://tiles.openfreemap.org/styles/dark")!
    }

    /// Версия стиля для пометки «устарел» у скачанных регионов.
    /// ЕДИНАЯ для дневного и ночного: тайлы общие, переключение
    /// день/ночь не делает пак устаревшим.
    static var styleVersion: String {
        file.styleVersion ?? "chappe-styles-2026-07-31"
    }

    /// Диапазон зумов региона по умолчанию (ADR 003: основная масса — z14;
    /// если регион тяжёлый, первый рычаг — ограничить 13-м).
    static let defaultMinZoom = 0
    static let defaultMaxZoom = 14

    /// Оценка среднего веса векторного тайла для «показа веса до
    /// скачивания». Это ОЦЕНКА: замер 29.07 (Гибралтар) дал ~11 КБ/тайл,
    /// но там много моря; дефолт 45 КБ сознательно перезакладывается —
    /// безопаснее для дискового бюджета. В UI подпись «~» обязательна.
    static var estimatedTileBytes: Int64 {
        let v = UserDefaults.standard.integer(forKey: "map.estimatedTileBytes")
        if v > 0 { return Int64(v) }
        return file.estimatedTileBytes ?? 45_000
    }

    /// Дисковый бюджет: предупреждение, если после скачивания останется
    /// меньше этого запаса.
    static var minFreeDiskBytes: Int64 {
        let v = UserDefaults.standard.integer(forKey: "map.minFreeDiskBytes")
        if v > 0 { return Int64(v) }
        return file.minFreeDiskBytes ?? 500_000_000   // 500 МБ
    }

    /// Жёсткий потолок ОДНОГО пака (Ф2.1, бриф 31.07): экран позволял
    /// запросить ~5.4 ТБ (весь мир на z14). 500 МБ — это область
    /// порядка крупной европейской страны на z14 по фактическому
    /// замеру (~11 КБ/тайл): осмысленный предел «регион, не планета».
    static var maxPackBytes: Int64 {
        let v = UserDefaults.standard.integer(forKey: "map.maxPackBytes")
        if v > 0 { return Int64(v) }
        return file.maxPackBytes ?? 500_000_000       // 500 МБ
    }

    /// Порог «большого» пака: не запрет, а предупреждение ДО нажатия.
    static var warnPackBytes: Int64 {
        let v = UserDefaults.standard.integer(forKey: "map.warnPackBytes")
        if v > 0 { return Int64(v) }
        return file.warnPackBytes ?? 150_000_000      // 150 МБ
    }

    // MARK: Эфир (WP7)

    /// Потолок позиционных маячков в час на контакт. Обоснование
    /// (docs/map_layer.md §6): LOCATION-пакет мал, но каждый занимает
    /// эфирное время LoRa целиком; 6/час = раз в 10 минут — достаточно
    /// для пешехода (за 10 минут уходит ≤ 840 м, круг старения это
    /// честно показывает), и это ~2% дьюти-цикла узла в худшем случае.
    static var maxBeaconsPerHourPerContact: Int {
        let v = UserDefaults.standard.integer(forKey: "map.maxBeaconsPerHour")
        if v > 0 { return v }
        return file.maxBeaconsPerHour ?? 6
    }

    /// Порог утилизации канала (0…1), выше которого маячки подавляются —
    /// как погодные слои: интерактив важнее фона.
    static var beaconSuppressionUtilization: Double {
        let v = UserDefaults.standard.double(forKey: "map.beaconSuppressUtil")
        if v > 0 { return v }
        return file.beaconSuppressUtil ?? 0.5
    }
}
