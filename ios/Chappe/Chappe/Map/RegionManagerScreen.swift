import SwiftUI
import CoreLocation

// ============================================================================
// Менеджер регионов (WP2 + Ф2 брифа 31.07).
//
// Главная правка по понятности — ПОИСК ПО ИМЕНИ с автодополнением из
// встроенного офлайн-газеттира (без сетевых геокодеров): «Мос» →
// список с локальной оценкой веса, выбор задаёт имя и область одним
// тапом. Ручной путь остаётся: двигаешь карту — качаешь видимое.
//
// Защита от абсурда: экран позволял запросить ~5.4 ТБ (весь мир).
// Теперь: предупреждение при «большом» регионе ДО нажатия и жёсткий
// потолок на пак (конфиг, дефолт 500 МБ). Превью открывается на
// текущей области карты, не на мировом зуме.
//
// Скачивание только при интернете: по мешу тайлы не поедут никогда.
// ============================================================================

struct RegionManagerScreen: View {

    /// Область главной карты — стартовая камера превью (Ф2.1).
    var initialBBox: RegionBBox?

    @ObservedObject private var tiles = RegionDownloader.shared

    @State private var visibleBBox: RegionBBox?
    @State private var visibleZoom: Double = 0
    @State private var regionName = ""
    @State private var nameWasAutoFilled = true
    @State private var maxZoom = MapConfig.defaultMaxZoom
    @State private var downloadError: String?
    @State private var centerCommand: CLLocationCoordinate2D?
    @State private var boundsCommand: RegionBBox?
    @State private var searchText = ""
    @State private var suggestions: [RegionSuggestion] = []
    /// Пак, который новый регион повторяет больше чем наполовину (Ф2.3).
    @State private var overlapCandidate: MapRegion?

    var body: some View {
        List {
            searchSection
            newRegionSection
            downloadedSection
        }
        .scrollContentBackground(.hidden)
        .rmScreenBackground()
        .navigationTitle("Регионы карты")
        .navigationBarTitleDisplayMode(.inline)
        // Ф2.4: оборванные загрузки продолжаются при открытии экрана
        .onAppear {
            visibleBBox = visibleBBox ?? initialBBox
            // Правка 31.07: главная карта могла ещё не отдать область
            // (открыли регионы сразу) — тогда превью стартовало с
            // мирового зума и оценка была ~5.4 ТБ. Запасная стартовая
            // область: вокруг последней своей позиции, ~50 км.
            if visibleBBox == nil, let fix = LocationProvider.shared.lastFix {
                let fallback = RegionBBox(minLat: fix.lat - 0.25,
                                          minLon: fix.lon - 0.25,
                                          maxLat: fix.lat + 0.25,
                                          maxLon: fix.lon + 0.25)
                visibleBBox = fallback
                boundsCommand = fallback
            }
            tiles.resumeInterruptedDownloads()
        }
        .alert("Не получилось", isPresented: .init(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
        .confirmationDialog(
            overlapTitle,
            isPresented: .init(get: { overlapCandidate != nil },
                               set: { if !$0 { overlapCandidate = nil } }),
            titleVisibility: .visible) {
            Button("Заменить существующий", role: .destructive) {
                if let old = overlapCandidate {
                    tiles.deleteRegion(id: old.id)
                }
                overlapCandidate = nil
                startDownload(skipOverlapCheck: true)
            }
            Button("Скачать оба") {
                overlapCandidate = nil
                startDownload(skipOverlapCheck: true)
            }
            Button("Отмена", role: .cancel) { overlapCandidate = nil }
        }
    }

    private var overlapTitle: String {
        "Область больше чем наполовину повторяет пак "
        + "«\(overlapCandidate?.name ?? "")». Заменить его?"
    }

    // MARK: Поиск по имени (Ф2.2)

    private var searchSection: some View {
        Section {
            TextField("Название города или области (например «Убуд»)",
                      text: $searchText)
                .autocorrectionDisabled()
                .onChange(of: searchText) {
                    suggestions = RegionGazetteer.shared.search(searchText)
                }
            ForEach(suggestions) { suggestion in
                Button {
                    choose(suggestion)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .foregroundStyle(RMDesign.textPrimary)
                            Text(suggestion.isArea ? "область" : "город")
                                .font(.system(size: 11))
                                .foregroundStyle(RMDesign.textTertiary)
                        }
                        Spacer()
                        // вес считается ЛОКАЛЬНО из bbox и зума
                        Text("~\(estimate(suggestion.bbox) / 1_000_000) МБ")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RMDesign.textSecondary)
                    }
                }
            }
        } header: {
            Text("Найти место")
                .foregroundStyle(RMDesign.textSecondary)
        } footer: {
            if suggestions.isEmpty, searchText.count >= 2 {
                Text("Не нашлось — подвиньте карту ниже руками: скачается "
                   + "видимая область.")
                    .foregroundStyle(RMDesign.textTertiary)
            }
        }
        .listRowBackground(RMDesign.surface1)
    }

    /// Выбор из списка: имя и область одним тапом.
    private func choose(_ suggestion: RegionSuggestion) {
        regionName = suggestion.name
        nameWasAutoFilled = false      // имя выбрано человеком
        boundsCommand = suggestion.bbox
        visibleBBox = suggestion.bbox
        searchText = ""
        suggestions = []
    }

    private func estimate(_ bbox: RegionBBox) -> Int64 {
        tiles.estimatedSizeBytes(bbox: bbox,
                                 minZoom: MapConfig.defaultMinZoom,
                                 maxZoom: maxZoom)
    }

    // MARK: Новый регион

    private var estimatedBytes: Int64? {
        visibleBBox.map(estimate)
    }

    private var newRegionSection: some View {
        Section("Скачать видимую область") {
            MapViewRepresentable(
                styleURL: tiles.styleURL,
                markers: [],
                coverageBBoxes: tiles.regions
                    .filter { $0.state == .ready || $0.state == .stale }
                    .map(\.bbox),
                now: Date(),
                centerCommand: $centerCommand,
                boundsCommand: $boundsCommand,
                initialBounds: initialBBox,
                onTapMarker: nil,
                onVisibleBoundsChanged: { bbox, zoom in
                    visibleBBox = bbox
                    visibleZoom = zoom
                    autoFillName(center: bbox)
                })
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            TextField("Имя региона", text: $regionName)
                .onChange(of: regionName) {
                    // человек начал печатать сам — автоподстановку выключаем
                    if !isProgrammaticNameChange { nameWasAutoFilled = false }
                }

            Picker("Максимальный зум", selection: $maxZoom) {
                Text("12 — обзор (лёгкий)").tag(12)
                Text("14 — детальный").tag(14)
            }

            // Вес до начала скачивания — обязателен по брифу.
            // Это оценка: реальный вес зависит от плотности данных OSM.
            if let bytes = estimatedBytes {
                HStack {
                    Text("Оценка веса")
                        .foregroundStyle(RMDesign.textSecondary)
                    Spacer()
                    Text(sizeText(bytes))
                        .fontWeight(.semibold)
                        .foregroundStyle(bytes > MapConfig.maxPackBytes
                                         ? RMDesign.warning
                                         : RMDesign.textPrimary)
                }
                // Ф2.1: предупреждение ДО нажатия и жёсткий потолок
                if bytes > MapConfig.maxPackBytes {
                    Text("Слишком большая область: \(sizeText(bytes)) при "
                       + "потолке \(sizeText(MapConfig.maxPackBytes)) на "
                       + "один пак. Приблизьте карту или выберите зум 12.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(RMDesign.warning)
                } else if bytes > MapConfig.warnPackBytes {
                    Text("Большой регион: займёт \(sizeText(bytes)) на "
                       + "диске, скачивание не быстрое.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(RMDesign.warning)
                }
            }

            Button {
                startDownload()
            } label: {
                Label("Скачать (нужен интернет)",
                      systemImage: "square.and.arrow.down")
            }
            .disabled(visibleBBox == nil
                      || regionName.trimmingCharacters(in: .whitespaces).isEmpty
                      || (estimatedBytes ?? 0) > MapConfig.maxPackBytes)
        }
        .listRowBackground(RMDesign.surface1)
    }

    /// Ф2.5: имя по умолчанию — из газеттира по центру видимой
    /// области, пока человек не задал своё.
    @State private var isProgrammaticNameChange = false

    private func autoFillName(center bbox: RegionBBox) {
        guard nameWasAutoFilled || regionName.isEmpty else { return }
        let lat = (bbox.minLat + bbox.maxLat) / 2
        let lon = (bbox.minLon + bbox.maxLon) / 2
        guard let name = RegionGazetteer.shared.name(atLat: lat, lon: lon),
              name != regionName else { return }
        isProgrammaticNameChange = true
        regionName = name
        nameWasAutoFilled = true
        isProgrammaticNameChange = false
    }

    private func sizeText(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000
            ? String(format: "~%.1f ГБ", Double(bytes) / 1_000_000_000)
            : "~\(bytes / 1_000_000) МБ"
    }

    private func startDownload(skipOverlapCheck: Bool = false) {
        guard let bbox = visibleBBox else { return }
        // Ф2.3: дубли — пересечение с существующим паком больше чем
        // наполовину → предупредить и предложить заменить
        if !skipOverlapCheck,
           let overlapping = tiles.regions
               .filter({ $0.state == .ready || $0.state == .stale })
               .first(where: { bbox.overlapRatio(with: $0.bbox) > 0.5 }) {
            overlapCandidate = overlapping
            return
        }
        do {
            try tiles.startDownload(
                name: regionName.trimmingCharacters(in: .whitespaces),
                bbox: bbox,
                minZoom: MapConfig.defaultMinZoom,
                maxZoom: maxZoom)
            regionName = ""
            nameWasAutoFilled = true
        } catch {
            downloadError = error.localizedDescription
        }
    }

    // MARK: Скачанное

    private var downloadedSection: some View {
        Section("Скачано") {
            if tiles.regions.isEmpty {
                Text("пока пусто — скачай первый регион перед выходом")
                    .foregroundStyle(RMDesign.textSecondary)
            }
            ForEach(tiles.regions) { region in
                regionRow(region)
            }
        }
        .listRowBackground(RMDesign.surface1)
    }

    @ViewBuilder
    private func regionRow(_ region: MapRegion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(region.name).fontWeight(.medium)
                Spacer()
                Text(stateText(region.state))
                    .font(.caption)
                    .foregroundStyle(stateColor(region.state))
            }
            HStack {
                Text("зум 0–\(region.maxZoom)")
                Spacer()
                if let bytes = region.sizeBytes {
                    Text(bytes < 1_000_000
                         ? "\(bytes / 1_000) КБ"
                         : "\(bytes / 1_000_000) МБ")
                }
            }
            .font(.caption)
            .foregroundStyle(RMDesign.textSecondary)

            if case .downloading(let progress) = region.state {
                ProgressView(value: progress)
                Button("Пауза") { tiles.pauseDownload(id: region.id) }
                    .font(.caption)
            }
            if case .paused(let progress) = region.state {
                ProgressView(value: progress)
                Button("Продолжить") { tiles.resumeDownload(id: region.id) }
                    .font(.caption)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                tiles.deleteRegion(id: region.id)
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    private func stateText(_ state: RegionState) -> String {
        switch state {
        case .none: "не скачан"
        case .downloading(let p): "качается \(Int(p * 100))%"
        case .paused(let p): "пауза \(Int(p * 100))%"
        case .ready: "готов"
        case .stale: "устарел (стиль обновился)"
        }
    }

    private func stateColor(_ state: RegionState) -> Color {
        switch state {
        case .ready: RMDesign.success
        case .stale: RMDesign.warning
        case .downloading, .paused: RMDesign.accent
        case .none: RMDesign.textTertiary
        }
    }
}
