import SwiftUI
import CoreLocation

// ============================================================================
// Экран карты (WP5 + погода Б1, 06.08). Содержимое: своя позиция,
// позиции контактов с шерингом, метки SOS, индикатор покрытия,
// погодные слои (по умолчанию выключены, docs/weather_pack.md).
// Никаких маршрутов и компаса. Карта — НЕ стартовый экран (дом —
// чаты); задел под «полевой режим» — только флаг в MapConfig-будущем.
//
// Метки видимо стареют: TimelineView перерисовывает раз в 30 секунд,
// возраст и круг растут по правилам WP3 без единого таймера в моделях.
// ============================================================================

struct MapScreen: View {

    @EnvironmentObject private var router: TabRouter
    @ObservedObject private var peers = PeerPositionStore.shared
    @ObservedObject private var location = LocationProvider.shared
    @ObservedObject private var tiles = RegionDownloader.shared
    @ObservedObject private var weather = WeatherStore.shared

    @State private var weatherSheetShown = false
    /// Команда «покажи область» (демо-прогон погоды).
    @State private var demoBoundsCommand: RegionBBox?
    /// Пелена офлайн-покрытия — отдельный выключаемый слой.
    @AppStorage("map_coverage_veil") private var veilEnabled = true

    @State private var centerCommand: CLLocationCoordinate2D?
    @State private var selectedMarker: MapMarker?
    @State private var locatingFailed: String?
    /// Текущая видимая область — превью в менеджере регионов
    /// открывается на ней, а не на мировом зуме (Ф2.1).
    @State private var visibleBBox: RegionBBox?
    /// Режим стиля (день/ночь) — зеркало MapConfig.styleMode для
    /// перерисовки; истина хранится в UserDefaults.
    @State private var styleMode = MapConfig.styleMode
    /// Баннер «Офлайн-карт ещё нет» (полевой пакет 13.08): один показ
    /// за всю жизнь приложения, любое касание карты убирает — раньше
    /// висел постоянно и закрывал погоду.
    @State private var showOfflineHint = false
    static let offlineHintShownKey = "map.offlineHintShown"

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                mapBody(now: timeline.date)
            }
            .navigationTitle("Карта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // День/ночь (Ф3.2) — только карта, выбор запоминается
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        styleMode = styleMode == "light" ? "dark" : "light"
                        MapConfig.styleMode = styleMode
                    } label: {
                        Label(styleMode == "light"
                              ? "Ночной стиль" : "Дневной стиль",
                              systemImage: styleMode == "light"
                              ? "moon" : "sun.max")
                    }
                }
            }
            // dev: --weather-demo — включить температуру и показать юг
            // Вьетнама (скриншоты без рук, как --open-tab)
            .onAppear { weatherDemoIfAsked() }
            // Ф4 (30.07): карта центрируется на пользователе сама.
            // Открытие вкладки — событие пользователя, one-shot запрос
            // позиции (первый раз система покажет диалог разрешения).
            // Отказ карту НЕ ломает: работает без центрирования.
            .onAppear { autoCenterOnAppear() }
            // подсказка об офлайн-картах: решение о показе — ОДИН раз,
            // при первом открытии экрана без регионов; флаг ставится
            // сразу, чтобы повторные открытия её больше не показывали
            .onAppear {
                if tiles.regions.isEmpty,
                   !UserDefaults.standard.bool(
                        forKey: Self.offlineHintShownKey) {
                    showOfflineHint = true
                    UserDefaults.standard.set(
                        true, forKey: Self.offlineHintShownKey)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RegionManagerScreen(initialBBox: visibleBBox)
                    } label: {
                        Label("Регионы", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
    }

    private func markers(now: Date) -> [MapMarker] {
        var result: [MapMarker] = []
        if let own = location.lastFix {
            result.append(MapMarker(id: "own", kind: .own, fix: own))
        }
        let contactNames = Dictionary(
            uniqueKeysWithValues: ContactStore.load().map { ($0.id, $0.name) })
        for (contactID, fix) in peers.positions {
            result.append(MapMarker(
                id: "peer-\(contactID)",
                kind: .peer(contactID: contactID,
                            name: contactNames[contactID] ?? "Контакт"),
                fix: fix))
        }
        // SOS-метки: рендер и слой готовы (kind: .sos всегда поверх),
        // но приёма SOS-пакетов в DeliveryManager пока нет — источника
        // данных нет, честно нет и меток (REPORT_map_night.md).
        return result
    }

    @ViewBuilder
    private func mapBody(now: Date) -> some View {
        ZStack(alignment: .bottom) {
            MapViewRepresentable(
                styleURL: tiles.styleURL,
                markers: markers(now: now),
                coverageBBoxes: tiles.regions
                    .filter { $0.state == .ready || $0.state == .stale }
                    .map(\.bbox),
                now: now,
                weatherPack: weather.pack,
                weatherWorldPack: weather.worldPack,
                weatherActiveLayer: weather.activeLayer,
                weatherHourIdx: weather.hourIndex,
                weatherRenderable: weather.canRender
                    && weather.activeLayer != nil,
                // пелена не спорит с погодой: при активном слое гаснет
                showCoverageVeil: veilEnabled && weather.activeLayer == nil,
                centerCommand: $centerCommand,
                boundsCommand: $demoBoundsCommand,
                onTapMarker: { selectedMarker = $0 },
                onVisibleBoundsChanged: { bbox, _ in
                    visibleBBox = bbox
                    // погода следует за областью (дебаунс и пороги в сторе)
                    weather.viewportChanged(bbox)
                })
            // WP0 (02.08): карта НЕ уходит под таб-бар — стекло бара
            // сэмплирует фон за собой, и над светлой картой бар белел
            // (мог залипать и на соседних вкладках). Ограничение
            // safe-area — локально для экрана карты; за баром теперь
            // всегда тёмный фон приложения, appearance-прокси и окно
            // не тронуты. toolbarColorScheme стекло iOS 26 игнорирует —
            // проверено скриншотами.
            .background(RMDesign.background.ignoresSafeArea())

            // Ветер показывается движением, а не стрелками (заказ
            // владельца 08.08): частицы плывут по тому же полю u/v.
            // Слой живёт, только пока ветер включён и экран открыт.
            if weather.activeLayer == .wind, weather.canRender,
               let pack = weather.pack ?? weather.worldPack,
               let bbox = visibleBBox {
                WindParticlesView(pack: pack, hourIdx: weather.hourIndex,
                                  bbox: bbox)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Пометка свежести: ВСЕГДА видна при активном слое
                // (решение владельца 06.08 — не по тапу)
                if weather.activeLayer != nil {
                    HStack {
                        Spacer()
                        WeatherFreshnessBadge(store: weather, now: now) {
                            weatherSheetShown = true
                        }
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Шкала активного слоя — без легенды заливка
                        // не значит ничего (бриф п.4)
                        if let layer = weather.activeLayer,
                           weather.canRender {
                            WeatherScaleBar(layer: layer)
                                .frame(maxWidth: 230)
                        }
                        // Атрибуция ODbL — постоянно видима
                        Text("© OpenStreetMap contributors | OpenFreeMap © OpenMapTiles")
                            .font(.system(size: 9))
                            .foregroundStyle(RMDesign.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RMDesign.background.opacity(0.7),
                                        in: Capsule())
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        CoverageVeilButton(isOn: $veilEnabled)
                        WeatherLayerButtons(store: weather) {
                            onWeatherActivate()
                        }
                        Button {
                            recenterOnMe()
                        } label: {
                            Image(systemName: "location")
                                .font(.system(size: 18, weight: .semibold))
                                .padding(12)
                                .background(RMDesign.surface1, in: Circle())
                        }
                        .accessibilityLabel("Моё положение")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                if weather.activeLayer != nil {
                    WeatherTimelineBar(store: weather, now: now)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }

            if showOfflineHint, tiles.regions.isEmpty {
                // Подсказка первого открытия (полевой пакет 13.08):
                // раньше висела ПОСТОЯННО при пустых регионах и
                // закрывала погоду; теперь один показ, любой тап — уход
                VStack(spacing: 6) {
                    Text("Офлайн-карт ещё нет")
                        .font(.headline)
                    Text("Скачай регион по интернету заранее — по мешу тайлы не передаются")
                        .font(.caption)
                        .foregroundStyle(RMDesign.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .background(RMDesign.surface1,
                            in: RoundedRectangle(cornerRadius: 14))
                // при активной погоде снизу шкала и таймлайн — не заслонять
                .padding(.bottom, weather.activeLayer != nil ? 250 : 120)
            }

            if let message = locatingFailed {
                Text(message)
                    .font(.caption)
                    .padding(10)
                    .background(RMDesign.surface2,
                                in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 70)
            }
        }
        // любое касание экрана карты гасит подсказку офлайн-карт;
        // simultaneousGesture — карта продолжает получать свои жесты
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    if showOfflineHint { showOfflineHint = false }
                }
        )
        .sheet(isPresented: $weatherSheetShown) {
            WeatherAboutSheet(store: weather, now: now) {
                refreshWeather()
            }
            .presentationDetents([.height(340)])
            .presentationBackground(RMDesign.surface1)
        }
        .sheet(item: $selectedMarker) { marker in
            MarkerDetailSheet(marker: marker, now: now,
                              ownFix: location.lastFix) {
                router.selection = .chat
                selectedMarker = nil
            }
            .presentationDetents([.height(240)])
            .presentationBackground(RMDesign.surface1)
        }
    }

    private func weatherDemoIfAsked() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--weather-demo") else { return }
        // --weather-demo-world: мировой зум (bounds строго в ±180:
        // setVisibleCoordinateBounds за пределами вешает первый кадр)
        let demo = args.contains("--weather-demo-world")
            ? RegionBBox(minLat: -55.0, minLon: -179.0,
                         maxLat: 70.0, maxLon: 179.0)
            : RegionBBox(minLat: 8.0, minLon: 104.0,
                         maxLat: 13.0, maxLon: 110.0)
        demoBoundsCommand = demo
        let layerName = args.indices.contains(index + 1) ? args[index + 1] : ""
        weather.activeLayer = WeatherLayer(rawValue: layerName) ?? .temperature
        weather.disclaimerShown = true
        Task {
            await weather.ensureWorldPack()
            // мировое демо: только подложка (диагностика склейки)
            if !args.contains("--weather-demo-world") {
                await weather.refresh(viewport: demo)
            }
        }
        #endif
    }

    /// Активация слоя: дисклеймер (один раз) + закачка, если пак пустой
    /// или старше 6 часов. Отказ сети не шумит — плашка честная.
    private func onWeatherActivate() {
        if !weather.disclaimerShown {
            weatherSheetShown = true
        }
        let needsFetch = weather.pack == nil
            || (weather.pack.map { $0.ageHours(now: Date()) > 6 } ?? true)
        if needsFetch { refreshWeather() }
    }

    private func refreshWeather() {
        guard let bbox = visibleBBox ?? defaultWeatherBBox() else { return }
        Task { await weather.refresh(viewport: bbox) }
    }

    /// Карта ещё не сообщила видимую область (первый кадр) — область
    /// вокруг своей позиции; нет и её — честно ничего не качаем.
    private func defaultWeatherBBox() -> RegionBBox? {
        guard let own = location.lastFix else { return nil }
        return RegionBBox(minLat: own.lat - 2.5, minLon: own.lon - 2.5,
                          maxLat: own.lat + 2.5, maxLon: own.lon + 2.5)
    }

    private func recenterOnMe() {
        locatingFailed = nil
        Task {
            switch await LocationProvider.shared.requestFix() {
            case .fix(let fix):
                centerCommand = CLLocationCoordinate2D(latitude: fix.lat,
                                                       longitude: fix.lon)
            case .denied:
                locatingFailed = "Нет разрешения на геопозицию (Настройки "
                    + "iPhone → \(AppIdentity.appName) → Геопозиция)"
            case .unavailable(let reason):
                locatingFailed = "Позиция недоступна: \(reason)"
            }
        }
    }

    /// Автоцентрирование при открытии вкладки. Свежий фикс уже есть —
    /// центрируемся мгновенно; нет — one-shot запрос. Отказ и сбой не
    /// шумят ошибкой на весь экран: карта остаётся рабочей, при отказе
    /// видна короткая подсказка, как включить.
    private func autoCenterOnAppear() {
        #if DEBUG
        // демо-прогон держит показанную область и не просит позицию
        if ProcessInfo.processInfo.arguments.contains("--weather-demo") {
            return
        }
        #endif
        if let own = location.lastFix {
            centerCommand = CLLocationCoordinate2D(latitude: own.lat,
                                                   longitude: own.lon)
            return
        }
        Task {
            switch await LocationProvider.shared.requestFix() {
            case .fix(let fix):
                centerCommand = CLLocationCoordinate2D(latitude: fix.lat,
                                                       longitude: fix.lon)
            case .denied:
                locatingFailed = "Нет разрешения на геопозицию — карта "
                    + "работает, но не центрируется. Включить: Настройки "
                    + "iPhone → \(AppIdentity.appName) → Геопозиция"
            case .unavailable:
                break   // авто-попытка: без фикса просто не центрируемся
            }
        }
    }
}

// MARK: - Шторка метки

/// Нижняя шторка по тапу: имя, возраст, расстояние по прямой, азимут,
/// качество канала, переход в чат.
struct MarkerDetailSheet: View {
    let marker: MapMarker
    let now: Date
    let ownFix: PositionFix?
    let openChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(MarkerRendering.dotColor(for: marker, now: now))
                    .frame(width: 14, height: 14)
                Text(marker.title)
                    .font(.title3.bold())
                Spacer()
            }

            row("Позиция",
                String(format: "%.5f, %.5f", marker.fix.lat, marker.fix.lon))
            row("Возраст", MarkerRendering.ageLabel(for: marker, now: now)
                + String(format: " · круг ~%.0f м",
                         marker.fix.uncertaintyRadius(now: now)))

            if case .peer = marker.kind, let own = ownFix {
                let meters = GeoMath.distanceMeters(
                    lat1: own.lat, lon1: own.lon,
                    lat2: marker.fix.lat, lon2: marker.fix.lon)
                let bearing = GeoMath.initialBearingDegrees(
                    lat1: own.lat, lon1: own.lon,
                    lat2: marker.fix.lat, lon2: marker.fix.lon)
                row("По прямой", meters < 1000
                    ? String(format: "%.0f м", meters)
                    : String(format: "%.1f км", meters / 1000))
                row("Азимут", String(format: "%.0f° (%@)", bearing,
                                     SophieTools.compassPoint(bearing)))
            }
            // Качества канала per-контакт в v1 нет — честная заглушка
            row("Канал", "н/д в v1")

            if case .peer = marker.kind {
                Button(action: openChat) {
                    Label("Открыть чат", systemImage: "message")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(RMDesign.textSecondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }
}
