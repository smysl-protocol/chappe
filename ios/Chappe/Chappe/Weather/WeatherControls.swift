import SwiftUI

// ============================================================================
// UI погодных слоёв (переделка 06.08 по брифу владельца):
// - слои взаимоисключающие: один активный, тап по активному выключает;
// - шкала обязательна: компактная легенда с подписями и единицами,
//   цвета берутся из ТЕХ ЖЕ опорных точек, что и заливка
//   (WeatherRender.legendStops) — разъехаться не могут;
// - пометка свежести всегда видна при активном слое; таймлайн как был.
// ============================================================================

/// Вертикальный столбик кнопок слоёв (правый край карты). Один активный.
struct WeatherLayerButtons: View {
    @ObservedObject var store: WeatherStore
    /// Активация слоя (для дисклеймера и закачки) — решает экран.
    var onActivate: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(WeatherLayer.allCases) { layer in
                let isOn = store.activeLayer == layer
                Button {
                    if isOn {
                        store.activeLayer = nil       // тап по активному = выкл
                    } else {
                        store.activeLayer = layer     // остальные гаснут сами
                        onActivate()
                    }
                } label: {
                    Image(systemName: layer.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isOn ? RMDesign.accentLight
                                              : RMDesign.textSecondary)
                        .padding(10)
                        .background(isOn ? RMDesign.accentSurface
                                         : RMDesign.surface1,
                                    in: Circle())
                        .overlay(Circle().strokeBorder(
                            isOn ? RMDesign.accent : .clear, lineWidth: 1.5))
                }
                .accessibilityLabel(layer.title
                    + (isOn ? ", включено" : ", выключено"))
            }
        }
    }
}

/// Тумблер пелены офлайн-покрытия — отдельный слой карты (бриф п.2).
struct CoverageVeilButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "square.dashed.inset.filled"
                                   : "square.dashed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? RMDesign.textPrimary
                                      : RMDesign.textTertiary)
                .padding(10)
                .background(RMDesign.surface1, in: Circle())
        }
        .accessibilityLabel("Границы офлайн-карт"
            + (isOn ? ", показаны" : ", скрыты"))
    }
}

/// Компактная шкала активного слоя: градиент из опорных точек шкалы
/// заливки + подписи значений и единица измерения.
struct WeatherScaleBar: View {
    let layer: WeatherLayer

    var body: some View {
        let stops = WeatherRender.legendStops(for: layer)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                LinearGradient(
                    stops: gradientStops(stops),
                    startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8)
                    .clipShape(Capsule())
                Text(WeatherRender.legendUnit(for: layer))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RMDesign.textSecondary)
            }
            // подписи под соответствующими точками градиента
            GeometryReader { geo in
                ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                    if !stop.label.isEmpty {
                        Text(stop.label)
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(RMDesign.textSecondary)
                            .position(
                                x: geo.size.width * fraction(stops, i),
                                y: 6)
                    }
                }
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RMDesign.background.opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func fraction(_ stops: [WeatherRender.LegendStop],
                          _ i: Int) -> CGFloat {
        let lo = stops.first!.value, hi = stops.last!.value
        return CGFloat((stops[i].value - lo) / (hi - lo))
    }

    private func gradientStops(_ stops: [WeatherRender.LegendStop])
        -> [Gradient.Stop] {
        let lo = stops.first!.value, hi = stops.last!.value
        return stops.map { s in
            Gradient.Stop(
                color: Color(red: Double(s.color.r) / 255,
                             green: Double(s.color.g) / 255,
                             blue: Double(s.color.b) / 255),
                location: (s.value - lo) / (hi - lo))
        }
    }
}

/// Пометка свежести — видна всегда, когда есть активный слой.
/// Тон спокойный (правка владельца 06.08): старые данные — жёлтая
/// капсула с часами, не красный алерт; сбой сети — нейтральная
/// приписка, старый прогноз при этом остаётся полезным.
struct WeatherFreshnessBadge: View {
    @ObservedObject var store: WeatherStore
    let now: Date
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if store.isFetching {
                    ProgressView().controlSize(.mini)
                    Text("обновляю прогноз…")
                } else if let line = store.ageLine(now: now) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    // род сбоя называет стор: «нет сети» только когда
                    // сети правда нет, отказ сервиса — своими словами
                    Text(store.fetchError.map { "\($0) · \(line)" } ?? line)
                } else {
                    Text(store.fetchError ?? "прогноз ещё не загружен")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(aged ? RMDesign.background : RMDesign.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(aged ? RMDesign.warning.opacity(0.92)
                             : RMDesign.background.opacity(0.85),
                        in: Capsule())
        }
        .accessibilityLabel("Свежесть прогноза; подробности по нажатию")
    }

    /// Жёлтая капсула — только когда данные действительно старые.
    private var aged: Bool {
        switch store.freshness(now: now) {
        case .stale, .beyondHorizon: true
        case .fresh, nil: false
        }
    }
}

/// Таймлайн прогноза (без изменений — «работает», бриф п.6).
struct WeatherTimelineBar: View {
    @ObservedObject var store: WeatherStore
    let now: Date

    var body: some View {
        if let pack = store.pack, store.canRender, !pack.hours.isEmpty {
            VStack(spacing: 4) {
                HStack {
                    Text(label(pack: pack, index: store.hourIndex))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    Spacer()
                    Text("до +\(pack.hours.last ?? 0) ч")
                        .font(.system(size: 10))
                        .foregroundStyle(RMDesign.textTertiary)
                }
                Slider(
                    value: Binding(
                        get: { Double(store.hourIndex) },
                        set: { store.hourIndex = Int($0.rounded()) }),
                    in: 0...Double(max(pack.hours.count - 1, 1)),
                    step: 1)
                .tint(RMDesign.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RMDesign.background.opacity(0.88),
                        in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func label(pack: WeatherPack, index: Int) -> String {
        let idx = min(index, pack.hours.count - 1)
        let date = pack.runDate.addingTimeInterval(
            Double(pack.hours[idx]) * 3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "E HH:mm"
        return formatter.string(from: date)
    }
}

/// Лист «о погодных слоях»: дисклеймер разрешения, возраст, атрибуция,
/// обновление.
struct WeatherAboutSheet: View {
    @ObservedObject var store: WeatherStore
    let now: Date
    var onRefresh: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Погодные слои")
                .font(.title3.bold())

            // Формулировка владельца (06.08) — дословно
            Label {
                Text("Это прогноз общей картины, не локальных явлений: "
                    + "шаг сетки — 13–27 км, локальный шквал или грозу "
                    + "над одной долиной она не видит. Не доверяйте "
                    + "картинке больше, чем она знает.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(RMDesign.warning)
            }
            .font(.subheadline)

            if let line = store.ageLine(now: now) {
                Label {
                    Text(line + " — возраст считается от расчёта "
                        + "прогноза, не от закачки")
                } icon: {
                    Image(systemName: "clock")
                        .foregroundStyle(RMDesign.textSecondary)
                }
                .font(.subheadline)
            }
            if case .beyondHorizon = store.freshness(now: now) {
                Text("Все сроки загруженного прогноза уже позади, "
                    + "поэтому слои не показываются. Появится сеть — "
                    + "нажмите «Обновить».")
                    .font(.subheadline)
                    .foregroundStyle(RMDesign.danger)
            }

            Text(WeatherRemoteSource.attributionLine)
                .font(.caption)
                .foregroundStyle(RMDesign.textTertiary)

            Button {
                onRefresh()
                dismiss()
            } label: {
                Label("Обновить прогноз", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isFetching)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { store.disclaimerShown = true }
    }
}
