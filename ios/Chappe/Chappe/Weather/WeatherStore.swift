import Foundation
import Combine

// ============================================================================
// Состояние погодного слоя (docs/weather_pack.md). Владеет паком, кэшем
// на диске, активным слоем и таймлайном. Про внешний источник знает
// только через WeatherRemoteSource.fetch — формат ответа сюда не проникает.
//
// Переделка 06.08 (бриф владельца):
// - слои ВЗАИМОИСКЛЮЧАЮЩИЕ: активен один или ни одного;
// - данные следуют за видимой областью карты (как на референсе), без
//   привязки к скачанным офлайн-регионам; политика кэша ниже;
// - без сети остаётся последний пак со своей честной пометкой давности.
//
// Политика закачки при панорамировании (цифры — в отчёте):
// - пак качается с ЗАПАСОМ: область в 2 раза шире видимой по каждой
//   оси — панорамирование внутри запаса не стоит ни байта;
// - перезакачка только если видимая область вышла за пак (с зазором
//   10%) ИЛИ зум изменил желаемый шаг сетки;
// - дебаунс 1.2 с после остановки жеста и не чаще раза в 15 с
//   (исключение: видимая область полностью вне пака — сразу);
// - отказ сети ничего не ломает: прежний пак + пометка возраста.
//
// Политика давности (без изменений, решение 06.08):
// - ≤ 24 ч — обычная пометка; > 24 ч — показ с красной пометкой;
// - все сроки пака позади — слои не рисуются, плашка честная.
// ============================================================================

/// Слои погоды. Взаимоисключающие: активен максимум один.
enum WeatherLayer: String, CaseIterable, Identifiable {
    case wind, temperature, precipCloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wind: "Ветер"
        case .temperature: "Температура"
        case .precipCloud: "Осадки и облака"
        }
    }

    var icon: String {
        switch self {
        case .wind: "wind"
        case .temperature: "thermometer.medium"
        case .precipCloud: "cloud.rain"
        }
    }
}

@MainActor
final class WeatherStore: ObservableObject {

    static let shared = WeatherStore()

    @Published private(set) var pack: WeatherPack?
    /// Мировая подложка (двухслойная схема 06.08): грубый пак на весь
    /// глобус (~91 КБ), обновляется раз в 6 ч. Всегда закрывает экран
    /// на любом зуме — детальный пак рисуется поверх. После перезапуска
    /// оба встают из кэша мгновенно.
    @Published private(set) var worldPack: WeatherPack?
    @Published private(set) var isFetching = false
    @Published private(set) var fetchError: String?
    private var isWorldFetching = false
    /// Активный слой; nil — погода выключена (по умолчанию).
    @Published var activeLayer: WeatherLayer? {
        didSet {
            UserDefaults.standard.set(activeLayer?.rawValue,
                                      forKey: Self.layerKey)
        }
    }
    /// Индекс срока таймлайна (в pack.hours).
    @Published var hourIndex = 0
    /// Дисклеймер о разрешении сетки показан хотя бы раз.
    @Published var disclaimerShown: Bool {
        didSet { UserDefaults.standard.set(disclaimerShown,
                                           forKey: Self.disclaimerKey) }
    }

    /// Метрики сессии — для отчёта и Dev.
    private(set) var lastFetchBytes = 0
    private(set) var lastFetchSeconds = 0.0
    private(set) var lastPackBytes = 0
    private(set) var sessionFetches = 0
    private(set) var sessionBytes = 0

    private var lastFetchDate: Date?
    /// Сервис попросил паузу (HTTP 429 + Retry-After): раньше этого
    /// срока не долбим — честность клиента (заказ владельца 08.08).
    private var rateLimitedUntil: Date?
    /// Пауза, когда 429 пришёл без Retry-After.
    static let defaultRatePause: TimeInterval = 300
    private var debounceTask: Task<Void, Never>?
    /// Последняя область, о которой сообщила карта: если она уехала,
    /// пока шла закачка, — докачиваем вдогонку (починка «зависшей
    /// области» 06.08).
    private var lastViewport: RegionBBox?

    private static let layerKey = "weather_layer_active"
    private static let disclaimerKey = "weather_disclaimer_shown"

    private init() {
        activeLayer = UserDefaults.standard.string(forKey: Self.layerKey)
            .flatMap(WeatherLayer.init(rawValue:))
        disclaimerShown = UserDefaults.standard.bool(forKey: Self.disclaimerKey)
        #if DEBUG
        if Self.stubAsked {
            worldPack = Self.makeStubPack()
            disclaimerShown = true
            return   // в сеть и в кэш не ходим вовсе
        }
        #endif
        loadCachedPack()
    }

    /// Для тестов: изолированный экземпляр без синглтона и UserDefaults.
    // МЕГА-12 (14.08): dev-заглушка погодной службы. Сюита выжигала
    // ОБЩУЮ с приложением дневную квоту open-meteo (мой IP), и Wind-
    // приёмки краснели «нужен интернет без лимита» — сюита была
    // зелёной по квоте, а не детерминированно. UI-приёмки в Debug
    // получают синтетический мировой пак (--weather-stub) и в сеть не
    // ходят вовсе; их же ручной Release-прогон остаётся ЖИВОЙ приёмкой
    // (Release launch-аргументы не читает by design).
    #if DEBUG
    static var stubAsked: Bool {
        ProcessInfo.processInfo.arguments.contains("--weather-stub")
    }

    /// Синтетический мировой пак: крупная сетка, все обязательные
    /// поля, прогон «сейчас», горизонт 72 ч — шкала и частицы живут
    /// без сети. Форма JSON — та же, что у боевого пака.
    static func makeStubPack(now: Date = Date()) -> WeatherPack? {
        let latSteps = 14, lonSteps = 36, hourCount = 4
        let values = Array(repeating: 3,
                           count: latSteps * lonSteps * hourCount)
        let root: [String: Any] = [
            "format": "chappe.weather.pack", "version": 1,
            "model": "stub",
            "run_unix": now.timeIntervalSince1970,
            "fetched_unix": now.timeIntervalSince1970,
            "bbox": [-65.0, -175.0, 65.0, 175.0],
            "step_deg": 10.0,
            "hours": [0, 24, 48, 72],
            "fields": Dictionary(uniqueKeysWithValues:
                WeatherPack.requiredFields.map {
                    ($0, ["unit": "x", "scale": 1, "values": values])
                }),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root)
        else { return nil }
        return try? WeatherPack.decode(data, now: now)
    }
    #endif

    init(testPack: WeatherPack?) {
        activeLayer = nil
        disclaimerShown = true
        pack = testPack
    }

    // MARK: Давность (контракт: возраст — от прогона)

    enum Freshness: Equatable {
        case fresh(hours: Double)
        case stale(hours: Double)
        case beyondHorizon
    }

    func freshness(now: Date = Date()) -> Freshness? {
        guard let pack = pack ?? worldPack else { return nil }
        let age = pack.ageHours(now: now)
        if let last = pack.hours.last,
           now.timeIntervalSince(pack.runDate) > Double(last) * 3600 {
            return .beyondHorizon
        }
        return age > 24 ? .stale(hours: age) : .fresh(hours: age)
    }

    /// Строка возраста для пометки — всегда от прогона модели.
    func ageLine(now: Date = Date()) -> String? {
        guard pack != nil || worldPack != nil else { return nil }
        switch freshness(now: now) {
        case .beyondHorizon:
            return "прогноз закончился — нужна сеть"
        case .stale(let h):
            return "прогноз от \(Self.ageWords(h)) — данные старые"
        case .fresh(let h):
            return "прогноз от \(Self.ageWords(h))"
        case nil:
            return nil
        }
    }

    static func ageWords(_ hours: Double) -> String {
        if hours < 1 { return "этого часа" }
        if hours < 24 { return "\(Int(hours)) ч назад" }
        let days = Int(hours / 24)
        return days == 1 ? "вчера" : "\(days) дн назад"
    }

    /// Рисовать ли слои вообще (за горизонтом — нет).
    var canRender: Bool { canRenderAt(now: Date()) }

    func canRenderAt(now: Date) -> Bool {
        guard pack != nil || worldPack != nil else { return false }
        return freshness(now: now) != .beyondHorizon
    }

    // MARK: Мировая подложка

    /// Скачать/освежить мировую подложку (не чаще раза в 6 ч).
    func ensureWorldPack() async {
        if let wp = worldPack, wp.ageHours(now: Date()) < 6 { return }
        guard !isWorldFetching else { return }
        // пауза сервиса действует и на подложку (она не критична — молчим)
        if let until = rateLimitedUntil, Date() < until { return }
        isWorldFetching = true
        defer { isWorldFetching = false }
        do {
            let grid = WeatherRemoteSource.grid(
                forViewport: -85, lonMin: -180, latMax: 85, lonMax: 180)
            let result = try await WeatherRemoteSource.fetch(grid: grid)
            let decoded = try WeatherPack.decode(result.pack)
            worldPack = decoded
            sessionFetches += 1
            sessionBytes += result.downloadedBytes
            try? result.pack.write(to: Self.worldCacheURL, options: .atomic)
        } catch {
            // подложка не критична: остаётся прежняя или её нет
        }
    }

    // MARK: Следование за видимой областью

    /// Карта сообщила новую видимую область. Дебаунс + политика выше.
    func viewportChanged(_ bbox: RegionBBox) {
        guard activeLayer != nil else { return }
        #if DEBUG
        if Self.stubAsked { return }   // мировой стаб уже на месте
        #endif
        lastViewport = bbox
        Task { await ensureWorldPack() }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            if Self.decideRefetch(pack: self.pack, viewport: bbox,
                                  now: Date(),
                                  lastFetch: self.lastFetchDate) {
                await self.refresh(viewport: bbox)
            }
        }
    }

    /// Область закачки: видимая + запас 50% на сторону (в мировых
    /// границах). Окна больше НЕТ (решение 06.08 после полевых
    /// скриншотов): с потолком точек и параллельной закачкой весь мир
    /// помещается в один пак (~290 точек шагом 16°) — на обзорном зуме
    /// грузится сразу вся планета, при приближении сетка мельчает.
    nonisolated static func paddedFetchBBox(_ v: RegionBBox) -> RegionBBox {
        let padLat = (v.maxLat - v.minLat) * 0.5
        let padLon = (v.maxLon - v.minLon) * 0.5
        return RegionBBox(minLat: max(v.minLat - padLat, -85),
                          minLon: max(v.minLon - padLon, -180),
                          maxLat: min(v.maxLat + padLat, 85),
                          maxLon: min(v.maxLon + padLon, 180))
    }

    /// Чистая политика перезакачки — тестируется руками.
    nonisolated static func decideRefetch(pack: WeatherPack?,
                                          viewport: RegionBBox,
                                          now: Date,
                                          lastFetch: Date?) -> Bool {
        guard let pack else { return true }
        // видимая область целиком вне пака — качаем сразу
        let outside = viewport.minLat >= pack.latMax
            || viewport.maxLat <= pack.latMin
            || viewport.minLon >= pack.lonMax
            || viewport.maxLon <= pack.lonMin
        if outside { return true }
        // не чаще раза в 10 с
        if let last = lastFetch, now.timeIntervalSince(last) < 10 {
            return false
        }
        // вышли за пак с зазором 10% видимого размаха?
        let mLat = (viewport.maxLat - viewport.minLat) * 0.1
        let mLon = (viewport.maxLon - viewport.minLon) * 0.1
        let covered = viewport.minLat - mLat >= pack.latMin
            && viewport.maxLat + mLat <= pack.latMax
            && viewport.minLon - mLon >= pack.lonMin
            && viewport.maxLon + mLon <= pack.lonMax
        if !covered { return true }
        // зум изменил желаемый шаг сетки?
        let fetchArea = paddedFetchBBox(viewport)
        let desired = WeatherRemoteSource.grid(
            forViewport: fetchArea.minLat, lonMin: fetchArea.minLon,
            latMax: fetchArea.maxLat, lonMax: fetchArea.maxLon).step
        return desired < pack.stepDeg
    }

    // MARK: Закачка и кэш

    // MARK: Кэш паков сессии (полевое замечание 19.08)
    //
    // Шаг сетки следует за зумом (WeatherRemoteSource.grid), поэтому
    // каждый заметный зум раньше КАЧАЛ пак заново: ветер в той же точке
    // пересчитывался с других узлов («погода меняется при зуме»), а
    // серия зумов жгла минутную квоту сервиса (429 «просит паузу»).
    // Кэш держит недавние паки по шагам: возврат зума отдаёт ТОТ ЖЕ пак
    // мгновенно, без сети и без смены значений.

    private var packCache: [WeatherPack] = []
    private static let packCacheLimit = 6
    /// Окно переиспользования — заведомо внутри жизни прогона модели
    /// (новый прогон появляется раз в 3–6 ч).
    nonisolated static let packReuseWindow: TimeInterval = 20 * 60

    /// Чистый выбор пака из кэша: свежий, не грубее желаемого шага и
    /// покрывающий видимую область с тем же зазором 10%, что у
    /// decideRefetch (иначе у кромки пака кэш и перезакачка спорили бы
    /// вечно). Из подходящих берётся самый мелкий шаг.
    nonisolated static func reusablePack(from cache: [WeatherPack],
                                         viewport: RegionBBox,
                                         desiredStep: Double,
                                         now: Date) -> WeatherPack? {
        let mLat = (viewport.maxLat - viewport.minLat) * 0.1
        let mLon = (viewport.maxLon - viewport.minLon) * 0.1
        return cache.filter { p in
            now.timeIntervalSince(p.fetchedDate) <= packReuseWindow
                && p.stepDeg <= desiredStep + 1e-9
                && max(viewport.minLat - mLat, -85) >= p.latMin
                && min(viewport.maxLat + mLat, 85) <= p.latMax
                && max(viewport.minLon - mLon, -180) >= p.lonMin
                && min(viewport.maxLon + mLon, 180) <= p.lonMax
        }
        .min { $0.stepDeg < $1.stepDeg }
    }

    /// Положить пак в кэш: один пак на шаг (новая область вытесняет
    /// старую того же шага), сверх лимита умирает самый старый.
    nonisolated static func caching(_ pack: WeatherPack,
                                    into cache: [WeatherPack],
                                    limit: Int = packCacheLimit) -> [WeatherPack] {
        var out = cache.filter { $0.stepDeg != pack.stepDeg }
        out.append(pack)
        while out.count > limit,
              let oldest = out.min(by: { $0.fetchedDate < $1.fetchedDate }),
              let idx = out.firstIndex(where: {
                  $0.fetchedDate == oldest.fetchedDate }) {
            out.remove(at: idx)
        }
        return out
    }

    func refresh(viewport: RegionBBox) async {
        guard !isFetching else { return }
        // возврат зума: подходящий пак уже качали — сеть не нужна
        let plannedArea = Self.paddedFetchBBox(viewport)
        let plannedStep = WeatherRemoteSource.grid(
            forViewport: plannedArea.minLat, lonMin: plannedArea.minLon,
            latMax: plannedArea.maxLat, lonMax: plannedArea.maxLon).step
        if let cached = Self.reusablePack(from: packCache, viewport: viewport,
                                          desiredStep: plannedStep,
                                          now: Date()) {
            pack = cached
            hourIndex = min(hourIndex, cached.hours.count - 1)
            fetchError = nil
            return
        }
        // пауза по просьбе сервиса: не качаем и честно говорим, сколько ждать
        if let until = rateLimitedUntil {
            if Date() < until {
                fetchError = Self.pauseLine(until: until, now: Date())
                return
            }
            rateLimitedUntil = nil
        }
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        do {
            let padded = Self.paddedFetchBBox(viewport)
            let grid = WeatherRemoteSource.grid(
                forViewport: padded.minLat, lonMin: padded.minLon,
                latMax: padded.maxLat, lonMax: padded.maxLon)
            let result = try await WeatherRemoteSource.fetch(grid: grid)
            let decoded = try WeatherPack.decode(result.pack)
            pack = decoded
            packCache = Self.caching(decoded, into: packCache)
            hourIndex = min(hourIndex, decoded.hours.count - 1)
            lastFetchDate = Date()
            lastFetchBytes = result.downloadedBytes
            lastFetchSeconds = result.seconds
            lastPackBytes = result.pack.count
            sessionFetches += 1
            sessionBytes += result.downloadedBytes
            try? result.pack.write(to: Self.cacheURL, options: .atomic)
        } catch {
            // без домыслов: прежний пак + честная пометка возраста.
            // «нет сети» — только когда сети действительно нет; отказ
            // сервиса (лимит, 5xx) — другими словами (полевой урок
            // 07.08: бейдж врал «нет сети» при живом Wi-Fi)
            if case WeatherRemoteSource.SourceError
                .rateLimited(let after) = error {
                rateLimitedUntil = Date().addingTimeInterval(
                    after ?? Self.defaultRatePause)
            }
            fetchError = Self.fetchErrorLine(for: error)
            return
        }
        // Карта уехала, пока шла закачка (guard isFetching съел жест) —
        // докачиваем вдогонку, иначе старая область «зависает» до
        // следующего жеста. Только после УСПЕХА: при сбое не циклим.
        if let current = lastViewport,
           Self.decideRefetch(pack: pack, viewport: current,
                              now: Date(), lastFetch: nil) {
            Task { [weak self] in await self?.refresh(viewport: current) }
        }
    }

    /// Человеческая строка сбоя обновления — по РОДУ сбоя.
    nonisolated static func fetchErrorLine(for error: Error) -> String {
        if case WeatherRemoteSource.SourceError.rateLimited(let after) = error {
            guard let after, after >= 60 else {
                return "сервис погоды просит паузу — обновлю чуть позже"
            }
            return "сервис погоды просит паузу — обновлю через "
                + "\(Int((after / 60).rounded(.up))) мин"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .dataNotAllowed, .internationalRoamingOff:
                return "нет сети"
            case .timedOut:
                return "сервис не отвечает"
            default:
                break
            }
        }
        return "сервис погоды не ответил"
    }

    /// Строка на время действующей паузы (чистая — под замок).
    nonisolated static func pauseLine(until: Date, now: Date) -> String {
        let left = until.timeIntervalSince(now)
        guard left >= 60 else {
            return "сервис погоды просит паузу — обновлю чуть позже"
        }
        return "сервис погоды просит паузу — обновлю через "
            + "\(Int((left / 60).rounded(.up))) мин"
    }

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("weather", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    private static var cacheURL: URL {
        cacheDir.appendingPathComponent("pack.json")
    }

    private static var worldCacheURL: URL {
        cacheDir.appendingPathComponent("world.json")
    }

    private func loadCachedPack() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? WeatherPack.decode(data) {
            pack = cached
            lastPackBytes = data.count
        }
        if let data = try? Data(contentsOf: Self.worldCacheURL),
           let cached = try? WeatherPack.decode(data) {
            worldPack = cached
        }
    }
}
