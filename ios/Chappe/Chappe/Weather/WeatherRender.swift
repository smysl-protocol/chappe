import UIKit
import SwiftUI

// ============================================================================
// Рендер погодного пака: заливки, стрелки, шкалы. Чистая геометрия и
// цвет — про источник данных и MapLibre не знает.
//
// Переделка 06.08 (вечер, бриф владельца):
// - у КАЖДОГО слоя есть заливка (у ветра — скорость цветом, как на
//   референсе windfinder), палитры «холодное синее — горячее красное»;
// - стрелки ветра — регулярная сетка по ВИДИМОЙ области (не по узлам
//   пака): позиции прищёлкнуты к шагу, шаг зависит от зума; белые с
//   тёмной обводкой — читаемы на любом фоне; сила — длиной (масштаб),
//   направление — поворотом;
// - шкалы слоёв (legendStops) — ЕДИНСТВЕННЫЙ источник и для заливки,
//   и для легенды в UI: расхождение легенды с картинкой невозможно
//   по построению.
// ============================================================================

nonisolated enum WeatherRender {

    // MARK: Доступ к полю пака

    /// Значение поля в узле (физическое, с учётом scale).
    /// Ветер рисуется частицами, а не стрелками (заказ владельца 08.08).
    /// Оставлено переключателем: стрелочный путь цел и включается сменой
    /// на false, если частицы окажутся дороги по батарее.
    static let particlesReplaceArrows = true

    static func value(_ pack: WeatherPack, field: String,
                      hourIdx: Int, latIdx: Int, lonIdx: Int) -> Double {
        guard let f = pack.fields[field] else { return 0 }
        let nLat = pack.gridLatCount, nLon = pack.gridLonCount
        let i = hourIdx * nLat * nLon + latIdx * nLon + lonIdx
        guard f.values.indices.contains(i) else { return 0 }
        return Double(f.values[i]) * f.scale
    }

    /// Билинейная интерполяция по дробным координатам.
    /// Для массовых вызовов (заливка, частицы) — FieldSampler ниже:
    /// эта функция ищет поле в словаре при каждом вызове.
    static func sample(_ pack: WeatherPack, field: String, hourIdx: Int,
                       lat: Double, lon: Double) -> Double {
        FieldSampler(pack, field: field, hourIdx: hourIdx)?
            .sample(lat: lat, lon: lon) ?? 0
    }

    /// Быстрый доступ к одному полю на один срок. Поиск поля в словаре,
    /// размеры сетки и смещение часа считаются ОДИН раз — а не на каждый
    /// пиксель заливки и каждую частицу. Основание — вис карты 08.08:
    /// заливка мира это ~миллион вызовов sample() (каждый делал 4
    /// словарных поиска), частицы — ещё 28 800 вызовов в секунду; на
    /// главном потоке это съедало кадры целиком.
    struct FieldSampler {
        private let values: [Int]
        private let scale: Double
        private let base: Int          // hourIdx * nLat * nLon
        private let nLat: Int, nLon: Int
        private let latMin: Double, lonMin: Double, stepDeg: Double

        init?(_ pack: WeatherPack, field: String, hourIdx: Int) {
            guard let f = pack.fields[field] else { return nil }
            values = f.values
            scale = f.scale
            nLat = pack.gridLatCount
            nLon = pack.gridLonCount
            base = hourIdx * nLat * nLon
            latMin = pack.latMin
            lonMin = pack.lonMin
            stepDeg = pack.stepDeg
        }

        private func value(_ y: Int, _ x: Int) -> Double {
            let i = base + y * nLon + x
            guard values.indices.contains(i) else { return 0 }
            return Double(values[i]) * scale
        }

        func sample(lat: Double, lon: Double) -> Double {
            let la = ((lat - latMin) / stepDeg)
                .clamped(0, Double(nLat - 1))
            let lo = ((lon - lonMin) / stepDeg)
                .clamped(0, Double(nLon - 1))
            let la0 = Int(la), lo0 = Int(lo)
            let la1 = min(la0 + 1, nLat - 1)
            let lo1 = min(lo0 + 1, nLon - 1)
            let fa = la - Double(la0), fo = lo - Double(lo0)
            return value(la0, lo0) * (1 - fa) * (1 - fo)
                 + value(la1, lo0) * fa * (1 - fo)
                 + value(la0, lo1) * (1 - fa) * fo
                 + value(la1, lo1) * fa * fo
        }
    }

    // MARK: Шкалы слоёв — один источник для заливки И легенды

    struct LegendStop {
        let value: Double
        let color: (r: Int, g: Int, b: Int)
        let label: String
    }

    /// Опорные точки шкалы слоя. Палитры по логике референса:
    /// холодное/слабое — синее, горячее/сильное — красное, шторм —
    /// фиолетовый; осадки — по интенсивности синим в фиолетовый.
    static func legendStops(for layer: WeatherLayer) -> [LegendStop] {
        switch layer {
        case .temperature:
            return [
                LegendStop(value: -10, color: (74, 111, 216), label: "-10"),
                LegendStop(value: 0, color: (90, 200, 250), label: "0"),
                LegendStop(value: 10, color: (110, 205, 160), label: "10"),
                LegendStop(value: 20, color: (150, 200, 90), label: "20"),
                LegendStop(value: 27, color: (235, 195, 80), label: ""),
                LegendStop(value: 33, color: (240, 130, 60), label: "33"),
                LegendStop(value: 40, color: (220, 60, 50), label: "40"),
            ]
        case .wind:
            return [
                LegendStop(value: 0, color: (98, 135, 190), label: "0"),
                LegendStop(value: 3, color: (96, 180, 120), label: "3"),
                LegendStop(value: 6, color: (214, 196, 90), label: "6"),
                LegendStop(value: 9, color: (236, 140, 70), label: "9"),
                LegendStop(value: 12, color: (226, 80, 70), label: "12"),
                LegendStop(value: 15, color: (160, 70, 200), label: "15+"),
            ]
        case .precipCloud:
            return [
                LegendStop(value: 0, color: (120, 130, 150), label: "0"),
                LegendStop(value: 0.5, color: (140, 203, 255), label: "0.5"),
                LegendStop(value: 1, color: (100, 150, 240), label: "1"),
                LegendStop(value: 2, color: (80, 110, 225), label: "2"),
                LegendStop(value: 4, color: (91, 82, 217), label: "4"),
                LegendStop(value: 8, color: (60, 40, 160), label: "8+"),
            ]
        }
    }

    /// Единицы шкалы слоя (для легенды).
    static func legendUnit(for layer: WeatherLayer) -> String {
        switch layer {
        case .temperature: "°C"
        case .wind: "м/с"
        case .precipCloud: "мм/ч"
        }
    }

    /// Цвет по значению — интерполяция опорных точек шкалы.
    static func color(for layer: WeatherLayer, value x: Double)
        -> (r: Int, g: Int, b: Int) {
        let stops = legendStops(for: layer)
        if x <= stops.first!.value { return stops.first!.color }
        if x >= stops.last!.value { return stops.last!.color }
        for i in 1..<stops.count where x <= stops[i].value {
            let s0 = stops[i - 1], s1 = stops[i]
            let t = (x - s0.value) / (s1.value - s0.value)
            func mix(_ a: Int, _ b: Int) -> Int {
                Int(Double(a) + t * Double(b - a))
            }
            return (mix(s0.color.r, s1.color.r),
                    mix(s0.color.g, s1.color.g),
                    mix(s0.color.b, s1.color.b))
        }
        return stops.last!.color
    }

    // MARK: Картинка заливки

    static let pixelsPerCell = 8
    /// Прозрачность заливок (0…255): карта должна читаться сквозь слой.
    static let fillAlpha = 130

    /// RGBA-картинка слоя на область drawBounds (до краёв мира, если
    /// пак почти мировой); север — верхняя строка.
    static func fillImage(_ pack: WeatherPack, layer: WeatherLayer,
                          hourIdx: Int) -> UIImage? {
        let bounds = drawBounds(pack)
        let w = (pack.gridLonCount - 1) * pixelsPerCell + 1
        let h = (pack.gridLatCount - 1) * pixelsPerCell + 1
        guard w > 1, h > 1 else { return nil }
        // Поля ищутся один раз на картинку, не на каждый пиксель
        // (вис 08.08: мировая заливка — ~миллион пикселей)
        guard let pixel = pixelSampler(pack, layer: layer,
                                       hourIdx: hourIdx) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let latSpan = bounds.latMax - bounds.latMin
        let lonSpan = bounds.lonMax - bounds.lonMin
        for py in 0..<h {
            let lat = bounds.latMax - latSpan * Double(py) / Double(h - 1)
            for px in 0..<w {
                let lon = bounds.lonMin + lonSpan * Double(px) / Double(w - 1)
                let (x, alpha) = pixel(lat, lon)
                let c = color(for: layer, value: x)
                let o = (py * w + px) * 4
                let a = Double(alpha) / 255
                pixels[o] = UInt8(Double(c.r) * a)
                pixels[o + 1] = UInt8(Double(c.g) * a)
                pixels[o + 2] = UInt8(Double(c.b) * a)
                pixels[o + 3] = UInt8(alpha)
            }
        }
        let ctx = CGContext(data: &pixels, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = ctx?.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Значение слоя в точке + прозрачность пикселя (осадки без дождя —
    /// почти прозрачные, чтобы облака не глушили карту). Поля слоя
    /// находятся один раз — функция зовётся на каждый пиксель заливки.
    static func pixelSampler(_ pack: WeatherPack, layer: WeatherLayer,
                             hourIdx: Int)
        -> ((Double, Double) -> (value: Double, alpha: Int))? {
        switch layer {
        case .temperature:
            guard let t = FieldSampler(pack, field: "temp_2m",
                                       hourIdx: hourIdx) else { return nil }
            return { lat, lon in (t.sample(lat: lat, lon: lon), fillAlpha) }
        case .wind:
            guard let u = FieldSampler(pack, field: "wind_u10",
                                       hourIdx: hourIdx),
                  let v = FieldSampler(pack, field: "wind_v10",
                                       hourIdx: hourIdx) else { return nil }
            return { lat, lon in
                let uu = u.sample(lat: lat, lon: lon)
                let vv = v.sample(lat: lat, lon: lon)
                return ((uu * uu + vv * vv).squareRoot(), fillAlpha)
            }
        case .precipCloud:
            guard let p = FieldSampler(pack, field: "precip",
                                       hourIdx: hourIdx),
                  let c = FieldSampler(pack, field: "cloud_total",
                                       hourIdx: hourIdx) else { return nil }
            return { lat, lon in
                let rain = p.sample(lat: lat, lon: lon)
                if rain >= 0.1 {
                    return (rain, Int(110 + 110 * min(rain / 4.0, 1.0)))
                }
                // без дождя: лёгкая вуаль облачности
                let cloud = c.sample(lat: lat, lon: lon)
                return (0, Int(cloud / 100.0 * 70))
            }
        }
    }

    // MARK: Стрелки ветра — регулярная сетка по видимой области

    struct Arrow: Equatable {
        let lat: Double, lon: Double
        let bearingDeg: Double   // куда дует (0 = на север)
        let speedMS: Double
        let bucket: Int          // 0 тихо / 1 свежо / 2 сильно → длина
    }

    static func windBucket(_ speedMS: Double) -> Int {
        if speedMS < 4 { return 0 }
        if speedMS < 9 { return 1 }
        return 2
    }

    /// Куда дует: u — на восток, v — на север.
    static func bearing(u: Double, v: Double) -> Double {
        let deg = atan2(u, v) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// «Красивый» шаг сетки стрелок под видимый размах (градусы).
    static func arrowSpacing(forSpan span: Double,
                             targetPerAxis: Int = 9) -> Double {
        let raw = span / Double(targetPerAxis)
        let nice: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5]
        return nice.first { $0 >= raw } ?? 5
    }

    /// Стрелки по регулярной сетке на пересечении видимой области и
    /// области отрисовки пака. Позиции прищёлкнуты к шагу — при
    /// панорамировании сетка стоит на месте, а не ползёт за экраном.
    static func arrows(_ pack: WeatherPack, hourIdx: Int,
                       visibleLatMin: Double, visibleLonMin: Double,
                       visibleLatMax: Double, visibleLonMax: Double) -> [Arrow] {
        let bounds = drawBounds(pack)
        // мировой пак: по долготе не ограничиваем — стрелки ставятся и
        // на обёрнутых копиях мира (сэмпл по завёрнутой долготе)
        let worldWide = bounds.lonMax - bounds.lonMin >= 350
        let latMin = max(visibleLatMin, bounds.latMin)
        let latMax = min(visibleLatMax, bounds.latMax)
        let lonMin = worldWide ? visibleLonMin
                               : max(visibleLonMin, bounds.lonMin)
        let lonMax = worldWide ? visibleLonMax
                               : min(visibleLonMax, bounds.lonMax)
        guard latMin < latMax, lonMin < lonMax else { return [] }
        let span = max(visibleLatMax - visibleLatMin,
                       visibleLonMax - visibleLonMin)
        let spacing = arrowSpacing(forSpan: span)
        var out: [Arrow] = []
        var lat = (latMin / spacing).rounded(.up) * spacing
        while lat <= latMax {
            var lon = (lonMin / spacing).rounded(.up) * spacing
            while lon <= lonMax {
                // за пределами ±180 сэмплируем завёрнутую долготу
                let sampleLon = worldWide
                    ? (lon + 180).truncatingRemainder(dividingBy: 360)
                        .advanced(by: (lon + 180)
                            .truncatingRemainder(dividingBy: 360) < 0
                            ? 360 : 0) - 180
                    : lon
                let u = sample(pack, field: "wind_u10", hourIdx: hourIdx,
                               lat: lat, lon: sampleLon)
                let v = sample(pack, field: "wind_v10", hourIdx: hourIdx,
                               lat: lat, lon: sampleLon)
                let speed = (u * u + v * v).squareRoot()
                out.append(Arrow(lat: lat, lon: lon,
                                 bearingDeg: bearing(u: u, v: v),
                                 speedMS: speed,
                                 bucket: windBucket(speed)))
                lon += spacing
            }
            lat += spacing
        }
        return out
    }

    /// Иконка стрелки: тонкая, белая, БЕЗ обводки (правка владельца
    /// 06.08). Сила — длиной (iconScale по ведру).
    @MainActor
    static func arrowImage() -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 11, y: 2))        // остриё
            path.addLine(to: CGPoint(x: 14.6, y: 9))
            path.addLine(to: CGPoint(x: 11.9, y: 9))
            path.addLine(to: CGPoint(x: 11.9, y: 20))
            path.addLine(to: CGPoint(x: 10.1, y: 20))
            path.addLine(to: CGPoint(x: 10.1, y: 9))
            path.addLine(to: CGPoint(x: 7.4, y: 9))
            path.close()
            c.addPath(path.cgPath)
            c.setFillColor(UIColor(white: 1, alpha: 0.95).cgColor)
            c.fillPath()
        }
    }

    // MARK: Область отрисовки — дотянуть до краёв мира

    /// Сетка после клэмпа к ±85/±180 не дотягивает до краёв (шов у
    /// антимеридиана, «пустая» Гренландия): если зазор между краем
    /// пака и краем мира не больше шага — рисуем до края, продолжая
    /// крайние узлы (sample и так продолжает их константой).
    static func drawBounds(_ pack: WeatherPack)
        -> (latMin: Double, lonMin: Double, latMax: Double, lonMax: Double) {
        let s = pack.stepDeg
        return (
            pack.latMin - (-85) <= s ? -85 : pack.latMin,
            pack.lonMin - (-180) <= s ? -180 : pack.lonMin,
            85 - pack.latMax <= s ? 85 : pack.latMax,
            180 - pack.lonMax <= s ? 180 : pack.lonMax)
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(self, lo), hi)
    }
}
