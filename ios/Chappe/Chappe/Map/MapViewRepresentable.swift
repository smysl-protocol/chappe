import SwiftUI
import UIKit
import CoreLocation
import MapLibre

// ============================================================================
// Мост SwiftUI ↔ MLNMapView (WP5). Вся политика (что показывать, какими
// цветами, где серые зоны) приходит сверху готовыми данными; здесь только
// перевод в аннотации и полигоны MapLibre.
//
// Серая пелена: мировой полигон с дырками по bbox готовых регионов —
// человек видит границу СВОЕГО покрытия, а не пустую карту.
// ============================================================================

/// Точечная метка с полезной нагрузкой.
final class MarkerAnnotation: MLNPointAnnotation {
    var marker: MapMarker?
}

/// Круг неопределённости позиции.
final class UncertaintyPolygon: MLNPolygon {
    var dotColor: UIColor = .gray
}

/// Пелена «тайлов нет» (мир минус скачанные регионы).
final class CoverageVeilPolygon: MLNPolygon {}

struct MapViewRepresentable: UIViewRepresentable {

    let styleURL: URL
    var markers: [MapMarker]
    var coverageBBoxes: [RegionBBox]
    var now: Date
    /// Погодный слой (Б1, переделка 06.08): пак + активный слой + срок.
    /// renderable=false (за горизонтом) — слой снимается с карты.
    var weatherPack: WeatherPack?
    /// Мировая подложка: грубый глобус ПОД детальным паком — экран
    /// закрыт на любом зуме, склейка мира без дыр (копии ±360°).
    var weatherWorldPack: WeatherPack?
    var weatherActiveLayer: WeatherLayer?
    var weatherHourIdx: Int = 0
    var weatherRenderable: Bool = false
    /// Пелена офлайн-покрытия — отдельный выключаемый слой (бриф п.2).
    var showCoverageVeil: Bool = true
    /// Команда «центрируйся сюда»; после исполнения сбрасывается.
    @Binding var centerCommand: CLLocationCoordinate2D?
    /// Команда «покажи эту область» (выбор региона из газеттира);
    /// после исполнения сбрасывается.
    var boundsCommand: Binding<RegionBBox?> = .constant(nil)
    /// Начальная область камеры (превью регионов открывается на
    /// текущей области карты, а не на мировом зуме — Ф2.1).
    var initialBounds: RegionBBox?
    var onTapMarker: ((MapMarker) -> Void)?
    var onVisibleBoundsChanged: ((RegionBBox, Double) -> Void)?

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        // Кнопку атрибуции прятать запрещено (док MLNMapView); рядом на
        // экране есть и постоянная текстовая подпись OSM.
        map.attributionButton.tintColor = UIColor(RMDesign.textSecondary)
        map.allowsRotating = false   // v1: север сверху, компаса нет
        map.allowsTilting = false
        if let initial = initialBounds {
            map.setVisibleCoordinateBounds(Self.mlnBounds(initial),
                                           animated: false)
        }
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        // Переключение день/ночь (Ф3.2): стиль применяется на живой
        // карте, пересоздания вью нет
        if map.styleURL != styleURL {
            map.styleURL = styleURL
        }
        context.coordinator.sync(on: map)
        context.coordinator.applyWeather(on: map)
        if let center = centerCommand {
            map.setCenter(center, zoomLevel: max(map.zoomLevel, 13),
                          animated: true)
            Task { @MainActor in centerCommand = nil }
        }
        if let bounds = boundsCommand.wrappedValue {
            map.setVisibleCoordinateBounds(Self.mlnBounds(bounds),
                                           animated: true)
            Task { @MainActor in boundsCommand.wrappedValue = nil }
        }
    }

    static func mlnBounds(_ bbox: RegionBBox) -> MLNCoordinateBounds {
        MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: bbox.minLat,
                                       longitude: bbox.minLon),
            ne: CLLocationCoordinate2D(latitude: bbox.maxLat,
                                       longitude: bbox.maxLon))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Координатор

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: MapViewRepresentable

        init(_ parent: MapViewRepresentable) { self.parent = parent }

        /// Ключ последней синхронизации аннотаций: во время скачивания
        /// пака прогресс дёргает observable каждые доли секунды →
        /// updateUIView; полная замена аннотаций при КАЖДОМ вызове
        /// заставляла карту мерцать (баг 31.07). Данные не изменились —
        /// не трогаем ничего.
        private var lastSyncKey: Int?

        /// Перестраивает аннотации под текущие данные. Меток мало
        /// (свои+контакты+SOS), полная замена дешевле диффа — но только
        /// когда данные реально изменились.
        func sync(on map: MLNMapView) {
            var hasher = Hasher()
            hasher.combine(parent.showCoverageVeil)
            for bbox in parent.coverageBBoxes { hasher.combine(bbox) }
            for marker in parent.markers {
                hasher.combine(marker.id)
                hasher.combine(marker.fix.lat)
                hasher.combine(marker.fix.lon)
                hasher.combine(marker.fix.timestamp)
            }
            hasher.combine(parent.now)   // тик TimelineView (раз в 30 с)
            let key = hasher.finalize()
            if key == lastSyncKey { return }
            lastSyncKey = key

            if let old = map.annotations { map.removeAnnotations(old) }

            // Пелена непокрытых зон — отдельный слой, выключаемый
            // (и не спорящий с погодой: экран гасит его сам)
            if parent.showCoverageVeil {
                let world: [CLLocationCoordinate2D] = [
                    .init(latitude: -85, longitude: -179.9),
                    .init(latitude: 85, longitude: -179.9),
                    .init(latitude: 85, longitude: 179.9),
                    .init(latitude: -85, longitude: 179.9),
                ]
                let holes = parent.coverageBBoxes.map { bbox -> MLNPolygon in
                    var ring: [CLLocationCoordinate2D] = [
                        .init(latitude: bbox.minLat, longitude: bbox.minLon),
                        .init(latitude: bbox.maxLat, longitude: bbox.minLon),
                        .init(latitude: bbox.maxLat, longitude: bbox.maxLon),
                        .init(latitude: bbox.minLat, longitude: bbox.maxLon),
                    ]
                    return MLNPolygon(coordinates: &ring,
                                      count: UInt(ring.count))
                }
                var worldRing = world
                let veil = CoverageVeilPolygon(coordinates: &worldRing,
                                               count: UInt(worldRing.count),
                                               interiorPolygons: holes)
                map.addAnnotation(veil)
            }

            // Круги неопределённости — под точками
            for marker in parent.markers
            where MarkerRendering.isVisible(marker, now: parent.now) {
                var ring = MarkerRendering
                    .uncertaintyCircle(for: marker, now: parent.now)
                    .map { CLLocationCoordinate2D(latitude: $0.lat,
                                                  longitude: $0.lon) }
                if !ring.isEmpty {
                    let poly = UncertaintyPolygon(coordinates: &ring,
                                                  count: UInt(ring.count))
                    poly.dotColor = UIColor(
                        MarkerRendering.dotColor(for: marker, now: parent.now))
                    map.addAnnotation(poly)
                }
                let point = MarkerAnnotation()
                point.marker = marker
                point.coordinate = CLLocationCoordinate2D(
                    latitude: marker.fix.lat, longitude: marker.fix.lon)
                map.addAnnotation(point)
            }
        }

        // MARK: Погодные слои (Б1)

        /// Ключ последнего применённого погодного состояния — при
        /// каждом чихе updateUIView слои не пересобираются.
        private var lastWeatherKey: Int?

        /// Стиль пересоздаётся при смене день/ночь — погодные слои
        /// накатываются заново, когда стиль реально готов.
        nonisolated func mapView(_ mapView: MLNMapView,
                                 didFinishLoading style: MLNStyle) {
            MainActor.assumeIsolated {
                lastWeatherKey = nil
                applyWeather(on: mapView)
            }
        }

        /// Отложенное обновление стрелок (жест не должен дёргать стиль).
        private var arrowUpdateWork: DispatchWorkItem?
        private var lastArrowKey: Int?

        func applyWeather(on map: MLNMapView) {
            guard let style = map.style else { return }   // догонит didFinishLoading
            var hasher = Hasher()
            hasher.combine(parent.weatherPack?.runDate)
            hasher.combine(parent.weatherPack?.hours)
            hasher.combine(parent.weatherPack?.latMin)
            hasher.combine(parent.weatherPack?.lonMin)
            hasher.combine(parent.weatherWorldPack?.runDate)
            hasher.combine(parent.weatherHourIdx)
            hasher.combine(parent.weatherActiveLayer)
            hasher.combine(parent.weatherRenderable)
            let key = hasher.finalize()
            if key == lastWeatherKey { return }
            lastWeatherKey = key

            removeWeather(from: style)
            lastArrowKey = nil
            guard parent.weatherRenderable,
                  let layer = parent.weatherActiveLayer,
                  parent.weatherPack != nil
                    || parent.weatherWorldPack != nil else { return }

            // заливка — ПОД подписями базовой карты
            let labelLayer = style.layers.first { $0 is MLNSymbolStyleLayer }

            // Два слоя заливки, но ВИДЕН всегда ровно один (стыки и
            // двойная полупрозрачность исключены конструкцией):
            // детальный — когда покрывает весь экран, иначе мировой.
            // Переключение — сменой прозрачности в updateFillChoice.
            if let world = parent.weatherWorldPack,
               parent.weatherPack.map({ WeatherRender.drawBounds($0).lonMax
                   - WeatherRender.drawBounds($0).lonMin < 350 }) ?? true {
                addFill(world, layer: layer, suffix: "world",
                        style: style, below: labelLayer)
            }
            if let pack = parent.weatherPack {
                addFill(pack, layer: layer, suffix: "detail",
                        style: style, below: labelLayer)
            }
            lastDetailShown = nil
            updateFillChoice(on: map)

            // стрелки — только у ветра; слой создаётся пустым, наполняет
            // его updateArrows (и он же обновляет при панорамировании,
            // не трогая заливку — починка подвисаний 06.08)
            if layer == .wind {
                style.setImage(WeatherRender.arrowImage(),
                               forName: "chappe-weather-arrow")
                let source = MLNShapeSource(
                    identifier: "chappe-weather-arrows",
                    features: [], options: nil)
                style.addSource(source)
                let symbols = MLNSymbolStyleLayer(
                    identifier: "chappe-weather-arrows-layer", source: source)
                symbols.iconImageName = NSExpression(
                    forConstantValue: "chappe-weather-arrow")
                symbols.iconRotation = NSExpression(forKeyPath: "bearing")
                symbols.iconScale = NSExpression(forKeyPath: "scale")
                symbols.iconAllowsOverlap = NSExpression(forConstantValue: true)
                symbols.iconRotationAlignment = NSExpression(
                    forConstantValue: "map")
                style.addLayer(symbols)
                updateArrows(on: map, immediately: true)
            }
        }

        /// Какой слой заливки показан (nil — ещё не решали).
        private var lastDetailShown: Bool?

        /// Показать ровно один слой заливки: детальный, если он
        /// покрывает видимую область целиком, иначе мировой. Дёшево
        /// (только rasterOpacity) — зовётся и на каждом сдвиге карты.
        func updateFillChoice(on map: MLNMapView) {
            guard let style = map.style else { return }
            let visible = map.visibleCoordinateBounds
            let showDetail: Bool
            if let pack = parent.weatherPack {
                let b = WeatherRender.drawBounds(pack)
                // Видимая область на мировом зуме шире мира (карта
                // показывает копии, долгота уезжает за ±180, широта за
                // ±85) — сравнивать надо с миром, а не с числами MapLibre,
                // иначе «покрывает» не срабатывает никогда и экран
                // остаётся пустым (полевой дефект 08.08: на мировом зуме
                // не было заливки вообще).
                let vLatMin = max(visible.sw.latitude, -85)
                let vLatMax = min(visible.ne.latitude, 85)
                let vLonMin = max(visible.sw.longitude, -180)
                let vLonMax = min(visible.ne.longitude, 180)
                // пак шириной почти во весь мир покрывает любую долготу
                let coversAllLon = b.lonMax - b.lonMin >= 350
                showDetail = vLatMin >= b.latMin && vLatMax <= b.latMax
                    && (coversAllLon
                        || (vLonMin >= b.lonMin && vLonMax <= b.lonMax))
            } else {
                showDetail = false
            }
            if showDetail == lastDetailShown { return }
            lastDetailShown = showDetail
            for i in 0...2 {
                if let l = style.layer(withIdentifier:
                        "chappe-weather-fill-detail-\(i)")
                        as? MLNRasterStyleLayer {
                    l.rasterOpacity = NSExpression(
                        forConstantValue: showDetail ? 0.9 : 0)
                }
                if let l = style.layer(withIdentifier:
                        "chappe-weather-fill-world-\(i)")
                        as? MLNRasterStyleLayer {
                    l.rasterOpacity = NSExpression(
                        forConstantValue: showDetail ? 0 : 0.9)
                }
            }
        }

        /// Заливка пака тремя копиями (долгота −360/0/+360): image-source
        /// MapLibre не повторяется на обёрнутых копиях мира сам — копии
        /// закрывают склейку при любом центре карты.
        private func addFill(_ pack: WeatherPack, layer: WeatherLayer,
                             suffix: String, style: MLNStyle,
                             below labelLayer: MLNStyleLayer?) {
            let hourIdx = min(parent.weatherHourIdx, pack.hours.count - 1)
            guard let image = WeatherRender.fillImage(
                    pack, layer: layer, hourIdx: hourIdx) else { return }
            let b = WeatherRender.drawBounds(pack)
            for (i, shift) in [-360.0, 0, 360].enumerated() {
                let quad = MLNCoordinateQuadMake(
                    CLLocationCoordinate2D(latitude: b.latMax,
                                           longitude: b.lonMin + shift),
                    CLLocationCoordinate2D(latitude: b.latMin,
                                           longitude: b.lonMin + shift),
                    CLLocationCoordinate2D(latitude: b.latMin,
                                           longitude: b.lonMax + shift),
                    CLLocationCoordinate2D(latitude: b.latMax,
                                           longitude: b.lonMax + shift))
                let source = MLNImageSource(
                    identifier: "chappe-weather-src-\(suffix)-\(i)",
                    coordinateQuad: quad, image: image)
                style.addSource(source)
                let raster = MLNRasterStyleLayer(
                    identifier: "chappe-weather-fill-\(suffix)-\(i)",
                    source: source)
                raster.rasterOpacity = NSExpression(forConstantValue: 0.9)
                if let labelLayer {
                    style.insertLayer(raster, below: labelLayer)
                } else {
                    style.addLayer(raster)
                }
            }
        }

        /// Обновить ТОЛЬКО источник стрелок под видимую область.
        /// immediately — при создании слоя; иначе дебаунс 0.25 с,
        /// чтобы жест зума/скролла не дёргал стиль на каждый кадр.
        func updateArrows(on map: MLNMapView, immediately: Bool = false) {
            // Стрелки заменены анимацией частиц (WindParticles, 08.08):
            // ветер показывается движением, а не значками. Код стрелок
            // оставлен рабочим — это запасной путь, если частицы окажутся
            // дороги по батарее на слабых телефонах; включается снятием
            // этой проверки.
            guard !WeatherRender.particlesReplaceArrows else { return }
            guard parent.weatherActiveLayer == .wind,
                  parent.weatherRenderable,
                  let pack = parent.weatherPack
                    ?? parent.weatherWorldPack else { return }
            arrowUpdateWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak map] in
                guard let self, let map,
                      let style = map.style,
                      let source = style.source(
                        withIdentifier: "chappe-weather-arrows")
                        as? MLNShapeSource else { return }
                let b = map.visibleCoordinateBounds
                var hasher = Hasher()
                hasher.combine((b.sw.latitude * 50).rounded())
                hasher.combine((b.sw.longitude * 50).rounded())
                hasher.combine((b.ne.latitude * 50).rounded())
                hasher.combine((b.ne.longitude * 50).rounded())
                hasher.combine(min(self.parent.weatherHourIdx,
                                   pack.hours.count - 1))
                let key = hasher.finalize()
                if key == self.lastArrowKey { return }
                self.lastArrowKey = key
                let features = WeatherRender.arrows(
                        pack,
                        hourIdx: min(self.parent.weatherHourIdx,
                                     pack.hours.count - 1),
                        visibleLatMin: b.sw.latitude,
                        visibleLonMin: b.sw.longitude,
                        visibleLatMax: b.ne.latitude,
                        visibleLonMax: b.ne.longitude)
                    .map { arrow -> MLNPointFeature in
                        let f = MLNPointFeature()
                        f.coordinate = CLLocationCoordinate2D(
                            latitude: arrow.lat, longitude: arrow.lon)
                        let scale = [0.75, 1.0, 1.3][arrow.bucket]
                        f.attributes = ["bearing": arrow.bearingDeg,
                                        "scale": scale]
                        return f
                    }
                source.shape = MLNShapeCollectionFeature(shapes: features)
            }
            arrowUpdateWork = work
            if immediately {
                work.perform()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25,
                                              execute: work)
            }
        }

        private func removeWeather(from style: MLNStyle) {
            for layer in style.layers
            where layer.identifier.hasPrefix("chappe-weather-") {
                style.removeLayer(layer)
            }
            for source in style.sources
            where source.identifier.hasPrefix("chappe-weather-") {
                style.removeSource(source)
            }
        }

        // MARK: Стили полигонов

        nonisolated func mapView(_ mapView: MLNMapView,
                                 fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor {
            if annotation is CoverageVeilPolygon {
                return UIColor.black
            }
            if let poly = annotation as? UncertaintyPolygon {
                return poly.dotColor
            }
            return .clear
        }

        nonisolated func mapView(_ mapView: MLNMapView,
                                 alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
            if annotation is CoverageVeilPolygon {
                // Ф3.3: на дневном стиле 45% чёрного — грязный налёт;
                // непокрытость видна и при мягкой вуали
                return MainActor.assumeIsolated {
                    MapConfig.styleMode == "light" ? 0.22 : 0.45
                }
            }
            if annotation is UncertaintyPolygon { return 0.15 }
            return 1
        }

        nonisolated func mapView(_ mapView: MLNMapView,
                                 strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if let poly = annotation as? UncertaintyPolygon {
                return poly.dotColor.withAlphaComponent(0.6)
            }
            return .clear
        }

        // MARK: Метки

        nonisolated func mapView(_ mapView: MLNMapView,
                                 viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let annotation = annotation as? MarkerAnnotation,
                  let marker = annotation.marker else { return nil }
            return MainActor.assumeIsolated {
                let view = MLNAnnotationView(reuseIdentifier: nil)
                view.frame = CGRect(x: 0, y: 0, width: 120, height: 44)
                view.backgroundColor = .clear

                let isSOS = marker.kind == .sos
                let dotSize: CGFloat = isSOS ? 22 : 14
                let dot = UIView(frame: CGRect(
                    x: (view.bounds.width - dotSize) / 2, y: 0,
                    width: dotSize, height: dotSize))
                dot.layer.cornerRadius = dotSize / 2
                dot.backgroundColor = UIColor(
                    MarkerRendering.dotColor(for: marker, now: parent.now))
                dot.layer.borderColor = UIColor.white
                    .withAlphaComponent(isSOS ? 1 : 0.7).cgColor
                dot.layer.borderWidth = isSOS ? 3 : 1.5
                view.addSubview(dot)

                // Подпись: имя + возраст — на самой метке, не в попапе
                let label = UILabel(frame: CGRect(
                    x: 0, y: dotSize + 2, width: view.bounds.width, height: 26))
                label.numberOfLines = 2
                label.textAlignment = .center
                label.font = .systemFont(ofSize: 10, weight: isSOS ? .bold : .medium)
                // Подпись различима в обоих стилях карты (Ф3.3):
                // на дневном — тёмный текст со светлым гало
                let lightMap = MapConfig.styleMode == "light"
                label.textColor = lightMap
                    ? UIColor(white: 0.08, alpha: 1)
                    : UIColor(RMDesign.textPrimary)
                label.text = marker.title + "\n"
                    + MarkerRendering.ageLabel(for: marker, now: parent.now)
                label.layer.shadowColor = lightMap
                    ? UIColor.white.cgColor : UIColor.black.cgColor
                label.layer.shadowOpacity = 0.9
                label.layer.shadowRadius = 2
                label.layer.shadowOffset = .zero
                view.addSubview(label)

                view.alpha = MarkerRendering.opacity(for: marker, now: parent.now)
                // SOS — отдельный слой, всегда поверх остальных меток
                view.layer.zPosition = isSOS ? 1000 : 10
                view.centerOffset = CGVector(dx: 0, dy: -dotSize / 2)
                return view
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView,
                                 didSelect annotationView: MLNAnnotationView) {
            MainActor.assumeIsolated {
                guard let annotation = annotationView.annotation
                        as? MarkerAnnotation,
                      let marker = annotation.marker else { return }
                parent.onTapMarker?(marker)
                mapView.deselectAnnotation(annotation, animated: false)
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView,
                                 regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated {
                let b = mapView.visibleCoordinateBounds
                parent.onVisibleBoundsChanged?(
                    RegionBBox(minLat: b.sw.latitude, minLon: b.sw.longitude,
                               maxLat: b.ne.latitude, maxLon: b.ne.longitude),
                    mapView.zoomLevel)
                // поле стрелок следует за видимой областью: обновляется
                // ТОЛЬКО источник стрелок, с дебаунсом — заливка и стиль
                // не пересобираются (починка подвисаний при зуме 06.08)
                updateArrows(on: mapView)
                // выбор детальный/мировой слой — дёшево, без пересборки
                updateFillChoice(on: mapView)
            }
        }
    }
}
