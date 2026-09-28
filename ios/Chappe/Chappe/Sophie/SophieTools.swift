import Foundation
import UIKit
import CoreLocation

// ============================================================================
// Инструменты Софи, фаза 2а (sophie_presence §4): детерминированные,
// read-only, ноль радиотрафика. Считает КОД, модель только выбирает
// инструмент (вызов №1) и формулирует ответ по результату (вызов №2).
//
// v1: device_status / my_location / distance_eta.
// Слой карты (WP6): + peer_position (последняя позиция собеседника из
// PeerPositionStore, возраст данных обязателен) и tile_coverage (есть ли
// офлайн-тайлы в точке). Правило радио-тишины: инструменты не создают
// эфир; нет позиции — Софи говорит честно и может только ПРЕДЛОЖИТЬ
// попросить собеседника поделиться.
// ============================================================================

/// Какой инструмент выбрала модель. Enum-значения перечисляются в промпте
/// выбора (правило №8 CLAUDE.md); rawValue — как в схеме.
nonisolated enum SophieTool: String, Codable, CaseIterable, Sendable {
    case none
    case deviceStatus = "device_status"
    case myLocation = "my_location"
    case distanceEta = "distance_eta"
    case peerPosition = "peer_position"
    case tileCoverage = "tile_coverage"
    case weather
}

/// Результат вызова №1 — выбор инструмента и аргументы.
/// Swift-enum в поле tool отсекает выдуманные инструменты при парсинге.
nonisolated struct SophieToolCall: Decodable, Sendable {
    let tool: SophieTool
    var targetLat: Double?
    var targetLon: Double?
    var fromLat: Double?
    var fromLon: Double?
    /// Имя населённого пункта-цели (вместо координат) — ищется в
    /// офлайн-газетире точным совпадением без регистра.
    var targetName: String?
    /// Имя контакта для peer_position (ищется в списке контактов).
    var contactName: String?

    enum CodingKeys: String, CodingKey {
        case tool
        case targetLat = "target_lat", targetLon = "target_lon"
        case fromLat = "from_lat", fromLon = "from_lon"
        case targetName = "target_name"
        case contactName = "contact_name"
    }
}

nonisolated enum SophieTools {

    /// Пешая скорость из sophie_presence §4.
    static let walkingSpeedKmh = 4.5

    /// Честный ответ, когда модель не установлена/не загружена (п.6
    /// плана 29.07): гео-функции, газетир и грант работают без модели,
    /// но помощник — нет. Не падаем и не молчим.
    static let assistantUnavailableSummary =
        "помощник не установлен: локальная модель ещё не загружена. "
        + "Карта, справочник мест и шеринг позиции работают и без него"

    /// JSON-схема выбора инструмента (для провайдеров со structured
    /// output; локальный идёт fallback-путём валидация+repair).
    static let selectionSchemaJSON = """
    {
      "type": "object",
      "properties": {
        "tool": {"type": "string",
                 "enum": ["none", "device_status", "my_location", "distance_eta",
                          "peer_position", "tile_coverage", "weather"]},
        "target_lat": {"type": "number"},
        "target_lon": {"type": "number"},
        "from_lat": {"type": "number"},
        "from_lon": {"type": "number"},
        "target_name": {"type": "string"},
        "contact_name": {"type": "string"}
      },
      "required": ["tool"],
      "additionalProperties": false
    }
    """

    static let selectionSpec = StructuredSpec(jsonSchema: selectionSchemaJSON)

    /// Промпт вызова №1. Правило №8: значения tool перечислены явно.
    static func selectionPrompt(for message: String) -> String {
        """
        Определи, нужен ли инструмент, чтобы ответить на сообщение пользователя.
        Ответь ТОЛЬКО JSON вида {"tool": "...", ...}.
        tool — строго одно из значений: none, device_status, my_location, distance_eta, \
        peer_position, tile_coverage, weather.
        - device_status: спрашивают про батарею/зарядку, время, дату или какая модель работает
        - my_location: спрашивают «где я», мои координаты, мою позицию
        - distance_eta: спрашивают расстояние или сколько идти/добираться до точки; \
        координаты цели передай числами в target_lat и target_lon; если цель названа \
        ИМЕНЕМ населённого пункта — передай его в target_name в ИМЕНИТЕЛЬНОМ падеже, \
        без предлогов («до Касабланки» и «в Касабланке» → «Касабланка»); если \
        названы ОБЕ точки — вторую передай в from_lat и from_lon. Так же выбери \
        distance_eta с target_name, если человек утверждает или спорит, ГДЕ вы \
        находитесь («мне кажется мы в X», «разве это не X?») — проверим X по \
        справочнику
        - peer_position: спрашивают, ГДЕ СОБЕСЕДНИК/контакт («где он», «где Сергей», \
        «далеко ли он») — имя контакта, если названо, передай в contact_name
        - tile_coverage: спрашивают, есть ли КАРТА/тайлы для места, скачана ли карта \
        здесь или в точке; координаты точки, если названы, передай в target_lat/target_lon
        - weather: спрашивают погоду, дождь, ветер, температуру или облачность — \
        сейчас или в месте; координаты передай в target_lat/target_lon, ИМЯ места — \
        в target_name в ИМЕНИТЕЛЬНОМ падеже
        - none: всё остальное (обычный разговор, вопросы не про устройство и не про позицию)

        Сообщение: \(message)
        """
    }

    static func validate(_ call: SophieToolCall) throws {
        if call.tool == .distanceEta {
            if let lat = call.targetLat, let lon = call.targetLon {
                guard (-90...90).contains(lat), (-180...180).contains(lon) else {
                    throw ValidationError("координаты цели вне диапазона: \(lat), \(lon)")
                }
            } else if !(call.targetName?.isEmpty == false) {
                throw ValidationError("для distance_eta нужны target_lat и "
                                    + "target_lon или target_name")
            }
        }
    }

    struct ValidationError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Гаверсинус и ETA — считает код, не модель (§4)

    /// Расстояние по большому кругу, км.
    static func haversineKm(lat1: Double, lon1: Double,
                            lat2: Double, lon2: Double) -> Double {
        let r = 6371.0088   // средний радиус Земли, км
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let dφ = (lat2 - lat1) * .pi / 180
        let dλ = (lon2 - lon1) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2)
              + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Человекочитаемые расстояние и пешее время.
    static func distanceSummary(km: Double) -> String {
        let hours = km / walkingSpeedKmh
        let distanceText = km < 1
            ? String(format: "%.0f м", km * 1000)
            : String(format: "%.1f км", km)
        let etaText: String
        if hours < 1 {
            etaText = String(format: "~%.0f мин", hours * 60)
        } else if hours < 48 {
            etaText = String(format: "~%.1f ч", hours)
        } else {
            etaText = String(format: "~%.0f дней пути", hours / 24)
        }
        return "\(distanceText), пешком (\(walkingSpeedKmh) км/ч) \(etaText)"
    }

    // MARK: Выполнение инструментов

    /// Итог выполнения — текст для промпта вызова №2 (модель формулирует
    /// ответ по нему) плюс флаг «координаты давние».
    struct ToolResult: Sendable {
        let summary: String
        var coordsAgeSeconds: Double?
        /// В результате есть координаты — вызову №2 добавляется жёсткий
        /// запрет угадывать географию (4B игнорирует его в системном
        /// промпте, но слушается рядом с данными).
        var involvesCoordinates: Bool = false
    }

    /// device_status: без разрешений, только системные API.
    @MainActor
    static func runDeviceStatus() -> ToolResult {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let batteryText = level < 0 ? "неизвестно (симулятор?)"
                                    : "\(Int(level * 100))%"
        let charging: String
        switch device.batteryState {
        case .charging: charging = "на зарядке"
        case .full: charging = "заряжена полностью, на питании"
        case .unplugged: charging = "не на зарядке"
        default: charging = "состояние зарядки неизвестно"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        let model = LLMModelConfig.loadActive().displayName
        return ToolResult(summary:
            "батарея: \(batteryText), \(charging); "
            + "сейчас: \(formatter.string(from: Date())); "
            + "активная модель: \(model)")
    }

    /// my_location: one-shot CoreLocation. Возвращает и ветку отказа.
    @MainActor
    static func runMyLocation() async -> ToolResult {
        let outcome = await LocationFetcher().fetch()
        return renderLocation(outcome)
    }

    /// Чистая функция для тестов: формат каждого исхода. При фиксе —
    /// сразу газетир: «Мы сейчас примерно здесь: <пункт>» (правило «мы»:
    /// Софи живёт в этом телефоне).
    static func renderLocation(_ outcome: LocationFetcher.Outcome) -> ToolResult {
        switch outcome {
        case .location(let lat, let lon, let age):
            let ageText = age < 30 ? "фикс свежий"
                : age < 3600 ? String(format: "фикс %.0f мин назад", age / 60)
                : String(format: "фикс %.1f ч назад — данные давние", age / 3600)
            let coords = String(format: "%.5f, %.5f", lat, lon)
            let context = GazetteerStore.shared.locate(lat: lat, lon: lon)
            var summary: String
            if context.candidates.isEmpty {
                summary = "позиция: \(coords) (\(ageText))"
            } else {
                summary = "Мы сейчас примерно здесь: "
                        + "\(GazetteerStore.phrase(for: context)) "
                        + "(\(coords)); \(ageText)\n"
                        + "Ближайшие пункты (топ-5):\n"
                        + GazetteerStore.candidatesBlock(context)
            }
            return ToolResult(summary: summary,
                              coordsAgeSeconds: age, involvesCoordinates: true)
        case .denied:
            return ToolResult(summary:
                "доступ к геопозиции не разрешён; включается в Настройках "
                + "телефона: Настройки → Конфиденциальность → Службы "
                + "геолокации → \(AppIdentity.appName) → «При использовании»")
        case .unavailable(let reason):
            return ToolResult(summary: "позицию получить не удалось: \(reason)")
        }
    }

    /// distance_eta: цель обязательна; отправная точка — из аргументов
    /// или my_location.
    @MainActor
    static func runDistanceEta(_ call: SophieToolCall) async -> ToolResult {
        let toLat: Double, toLon: Double
        var targetLabel: String?

        if let lat = call.targetLat, let lon = call.targetLon {
            toLat = lat; toLon = lon
        } else if let name = call.targetName, !name.isEmpty {
            // Имя цели → офлайн-газетир: точный матч, затем допуск
            // в одну букву (опечатки/варианты вроде Касабланка↔Казабланка)
            let (hits, corrected) = GazetteerStore.shared.findFuzzy(name: name)
            switch hits.count {
            case 0:
                return ToolResult(summary:
                    "в офлайн-справочнике нет пункта «\(name)» — можно назвать "
                    + "координаты цели числами")
            case 1:
                toLat = hits[0].lat; toLon = hits[0].lon
                targetLabel = "\(hits[0].name) (\(hits[0].country))"
                    + (corrected
                       ? "; в справочнике имя записано как «\(hits[0].name)»"
                       : "")
            default:
                let variants = hits.prefix(3)
                    .map { "\($0.name) — \($0.country)" }
                    .joined(separator: "; ")
                return ToolResult(summary:
                    "пунктов с именем «\(name)» несколько: \(variants). "
                    + "Спроси пользователя, который из них имелся в виду")
            }
        } else {
            return ToolResult(summary: "не переданы координаты цели")
        }
        let fromLat: Double, fromLon: Double
        var age: Double?
        if let lat = call.fromLat, let lon = call.fromLon {
            fromLat = lat; fromLon = lon
        } else {
            switch await LocationFetcher().fetch() {
            case .location(let lat, let lon, let fixAge):
                fromLat = lat; fromLon = lon; age = fixAge
            case .denied:
                return renderLocation(.denied)
            case .unavailable(let reason):
                return ToolResult(summary:
                    "своя позиция недоступна (\(reason)) — расстояние не посчитать; "
                    + "можно назвать обе точки координатами")
            }
        }
        let km = haversineKm(lat1: fromLat, lon1: fromLon, lat2: toLat, lon2: toLon)
        let bearing = GeoMath.initialBearingDegrees(lat1: fromLat, lon1: fromLon,
                                                    lat2: toLat, lon2: toLon)
        let target = targetLabel ?? String(format: "%.5f, %.5f", toLat, toLon)
        var summary = "от \(String(format: "%.5f, %.5f", fromLat, fromLon)) "
                    + "до \(target): "
                    + distanceSummary(km: km)
                    + String(format: ", азимут %.0f° (%@)",
                             bearing, compassPoint(bearing))
                    + " (по прямой; маршрутов по дорогам нет)"
        if let age, age >= 3600 {
            summary += String(format: "; своя позиция давняя (%.1f ч)", age / 3600)
        }
        return ToolResult(summary: summary, coordsAgeSeconds: age,
                          involvesCoordinates: true)
    }

    /// weather: прогноз из СКАЧАННОГО погодного пака (WeatherStore,
    /// публичный API чужого модуля — сам модуль не правим). Спека Софи
    /// §2: погода — четвёртый источник фактов; возраст прогноза
    /// обязателен (контракт пака: возраст от runDate). Без пака —
    /// честный отказ, эфир и сеть не трогаются.
    @MainActor
    static func runWeather(_ call: SophieToolCall) async -> ToolResult {
        let lat: Double, lon: Double
        var label: String?
        if let tLat = call.targetLat, let tLon = call.targetLon {
            lat = tLat; lon = tLon
        } else if let name = call.targetName, !name.isEmpty {
            let (hits, _) = GazetteerStore.shared.findFuzzy(name: name)
            switch hits.count {
            case 0:
                return ToolResult(summary:
                    "в офлайн-справочнике нет пункта «\(name)» — можно "
                    + "назвать координаты точки числами")
            case 1:
                lat = hits[0].lat; lon = hits[0].lon
                label = "\(hits[0].name) (\(hits[0].country))"
            default:
                let variants = hits.prefix(3)
                    .map { "\($0.name) — \($0.country)" }
                    .joined(separator: "; ")
                return ToolResult(summary:
                    "пунктов с именем «\(name)» несколько: \(variants). "
                    + "Спроси пользователя, который имелся в виду")
            }
        } else {
            switch await LocationFetcher().fetch() {
            case .location(let myLat, let myLon, _):
                lat = myLat; lon = myLon; label = "вашей позиции"
            case .denied:
                return renderLocation(.denied)
            case .unavailable(let reason):
                return ToolResult(summary:
                    "своя позиция недоступна (\(reason)) — назови место "
                    + "именем или координатами")
            }
        }
        return renderWeather(pack: WeatherStore.shared.pack,
                             worldPack: WeatherStore.shared.worldPack,
                             lat: lat, lon: lon, label: label)
    }

    /// Чистый рендер прогноза — тестируется на стаб-паке без сети.
    @MainActor
    static func renderWeather(pack: WeatherPack?, worldPack: WeatherPack?,
                              lat: Double, lon: Double, label: String?,
                              now: Date = Date()) -> ToolResult {
        // Гейт bbox ОБЯЗАТЕЛЕН: сэмплер молча зажимает края сетки —
        // без проверки Софи «знала» бы погоду за пределами пака
        func covering(_ p: WeatherPack?) -> WeatherPack? {
            guard let p, (p.latMin...p.latMax).contains(lat),
                  (p.lonMin...p.lonMax).contains(lon) else { return nil }
            return p
        }
        guard let p = covering(pack) ?? covering(worldPack) else {
            return ToolResult(summary:
                "погодный пак для этой точки не скачан — офлайн-прогноза "
                + "нет. Погода скачивается на экране карты при интернете")
        }
        // Ближайший к «сейчас» срок прогона
        let age = p.ageHours(now: now)
        let hourIdx = p.hours.indices.min(by: {
            abs(Double(p.hours[$0]) - age) < abs(Double(p.hours[$1]) - age)
        }) ?? 0
        func value(_ field: String) -> Double {
            WeatherRender.sample(p, field: field, hourIdx: hourIdx,
                                 lat: lat, lon: lon)
        }
        let wind = (pow(value("wind_u10"), 2)
                    + pow(value("wind_v10"), 2)).squareRoot()
        let place = label ?? String(format: "%.3f, %.3f", lat, lon)
        // Возраст прогноза обязателен — контракт пака (от runDate)
        let summary = "офлайн-прогноз для \(place) "
            + "(модель \(p.model), прогону \(WeatherStore.ageWords(age)), "
            + "срок +\(p.hours[hourIdx]) ч): "
            + String(format: "температура ~%.0f °C, ветер ~%.0f м/с, ",
                     value("temp_2m"), wind)
            + String(format: "облачность %.0f %%, осадки %.1f мм/ч. ",
                     value("cloud_total"), value("precip"))
            + "Обязательно назови возраст прогноза"
        return ToolResult(summary: summary)
    }

    /// Сторона света по азимуту — для человеческого ответа Софи.
    static func compassPoint(_ bearingDegrees: Double) -> String {
        let names = ["север", "северо-восток", "восток", "юго-восток",
                     "юг", "юго-запад", "запад", "северо-запад"]
        let index = Int((bearingDegrees + 22.5)
            .truncatingRemainder(dividingBy: 360) / 45)
        return names[min(max(index, 0), 7)]
    }

    /// peer_position: последняя позиция собеседника из PeerPositionStore.
    /// Возраст данных ОБЯЗАТЕЛЕН в результате — точка без времени врёт.
    /// Радио-тишина: инструмент ничего не запрашивает по эфиру.
    @MainActor
    static func runPeerPosition(_ call: SophieToolCall,
                                contacts explicitContacts: [Contact]? = nil,
                                store: PeerPositionStore = .shared,
                                ownFix: PositionFix? = nil) -> ToolResult {
        let contacts = explicitContacts ?? ContactStore.load()
        guard !contacts.isEmpty else {
            return ToolResult(summary:
                "контактов пока нет — не у кого быть позиции. Обмен контактами "
                + "делается по QR во вкладке чатов")
        }

        let contact: Contact?
        if let name = call.contactName?.trimmingCharacters(in: .whitespaces),
           !name.isEmpty {
            contact = contacts.first {
                $0.name.lowercased().contains(name.lowercased())
            }
            guard contact != nil else {
                let known = contacts.map(\.name).joined(separator: ", ")
                return ToolResult(summary:
                    "контакта «\(name)» нет; есть: \(known)")
            }
        } else if contacts.count == 1 {
            contact = contacts[0]
        } else {
            let known = contacts.map(\.name).joined(separator: ", ")
            return ToolResult(summary:
                "контактов несколько (\(known)) — спроси пользователя, чья "
                + "позиция нужна")
        }

        guard let contact,
              let fix = store.position(for: contact.id) else {
            return ToolResult(summary:
                "позиции \(contact?.name ?? "контакта") ещё не приходило. "
                + "Можно ПРЕДЛОЖИТЬ попросить поделиться позицией в чате — "
                + "сам запрос по эфиру не отправляется",
                involvesCoordinates: false)
        }

        let age = max(0, -fix.timestamp.timeIntervalSinceNow)
        let coords = String(format: "%.5f, %.5f", fix.lat, fix.lon)
        let radius = PositionAging.uncertaintyRadius(
            accuracy: fix.horizontalAccuracy, ageSeconds: age)
        let ageText = age < 60 ? "только что"
            : age < 3600 ? String(format: "%.0f мин назад", age / 60)
            : age < 86_400 ? String(format: "%.1f ч назад", age / 3600)
            : String(format: "%.0f дн назад", age / 86_400)
        var summary = "\(contact.name): последняя известная позиция \(coords), "
            + "принята \(ageText)"
            + String(format: "; неопределённость ~%.0f м", radius)
        if let mine = ownFix ?? LocationProvider.shared.lastFix {
            let km = haversineKm(lat1: mine.lat, lon1: mine.lon,
                                 lat2: fix.lat, lon2: fix.lon)
            let bearing = GeoMath.initialBearingDegrees(
                lat1: mine.lat, lon1: mine.lon, lat2: fix.lat, lon2: fix.lon)
            summary += "; от нас: " + distanceSummary(km: km)
                + String(format: ", азимут %.0f° (%@), по прямой",
                         bearing, compassPoint(bearing))
        }
        return ToolResult(summary: summary, coordsAgeSeconds: age,
                          involvesCoordinates: true)
    }

    /// tile_coverage: есть ли офлайн-тайлы в точке (цель или своя позиция).
    @MainActor
    static func runTileCoverage(_ call: SophieToolCall,
                                coverage explicitCoverage: CoverageIndex? = nil,
                                readyRegionNames: [String]? = nil) async -> ToolResult {
        let lat: Double, lon: Double
        var age: Double?
        var whereText: String
        if let tLat = call.targetLat, let tLon = call.targetLon {
            lat = tLat; lon = tLon
            whereText = String(format: "в точке %.4f, %.4f", lat, lon)
        } else {
            switch await LocationFetcher().fetch() {
            case .location(let mLat, let mLon, let fixAge):
                lat = mLat; lon = mLon; age = fixAge
                whereText = "в нашей точке"
            case .denied:
                return renderLocation(.denied)
            case .unavailable(let reason):
                return ToolResult(summary:
                    "своя позиция недоступна (\(reason)) — можно назвать "
                    + "точку координатами")
            }
        }
        let coverage = explicitCoverage ?? RegionDownloader.shared.coverage()
        if let name = coverage.regionName(lat: lat, lon: lon) {
            return ToolResult(summary:
                "офлайн-карта \(whereText) есть: регион «\(name)»",
                coordsAgeSeconds: age)
        }
        let regions = readyRegionNames ?? RegionDownloader.shared.regions
            .filter { $0.state == .ready }.map(\.name)
        let downloaded = regions.isEmpty
            ? "скачанных регионов нет вовсе"
            : "скачано: \(regions.joined(separator: ", "))"
        return ToolResult(summary:
            "офлайн-карты \(whereText) НЕТ (\(downloaded)). Скачать регион "
            + "можно при интернете на экране карты — по мешу тайлы не передаются",
            coordsAgeSeconds: age)
    }

    /// Промпт вызова №2: результат инструмента + требования к ответу.
    static func answerBlock(for result: ToolResult) -> String {
        var block = "Результат инструмента (данные точные, посчитаны кодом "
                  + "на устройстве):\n\(result.summary)\n"
                  + "Ответь по этим данным коротко и по-человечески."
        if let age = result.coordsAgeSeconds, age >= 3600 {
            block += " Обязательно назови возраст координат — они давние."
        }
        if result.involvesCoordinates {
            block += " ЗАПРЕЩЕНО добавлять географию сверх результата — карт "
                   + "нет, догадки неверны. Названия мест и страны бери ТОЛЬКО "
                   + "из результата, ничего не добавляй от себя."
        }
        return block
    }
}

// MARK: - One-shot геолокация

/// Однократный запрос позиции: разрешение When-In-Use + requestLocation.
@MainActor
final class LocationFetcher: NSObject, CLLocationManagerDelegate {

    nonisolated enum Outcome: Sendable {
        case location(lat: Double, lon: Double, ageSeconds: Double)
        case denied
        case unavailable(String)
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Outcome, Never>?

    func fetch() async -> Outcome {
        manager.delegate = self
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // Ответ придёт в didChangeAuthorization — там продолжим
        default:
            manager.requestLocation()
        }
        return await withCheckedContinuation { c in
            continuation = c
            if manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.manager.requestLocation()
            case .denied, .restricted:
                self.finish(.denied)
            case .notDetermined:
                break   // ждём решения пользователя
            @unknown default:
                self.finish(.unavailable("неизвестный статус разрешения"))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else {
                self.finish(.unavailable("пустой ответ геосервиса"))
                return
            }
            let age = max(0, -location.timestamp.timeIntervalSinceNow)
            self.finish(.location(lat: location.coordinate.latitude,
                                  lon: location.coordinate.longitude,
                                  ageSeconds: age))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(.unavailable(error.localizedDescription))
        }
    }
}
