import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
// «Помощник» (Ф1.1): включение локальной модели для живых людей.
// Загрузка из приложения с прогрессом, докачкой, отменой и проверкой
// SHA-256; по умолчанию только Wi-Fi. Импорт через Files — запасной
// путь (кнопка внизу). Пока модели нет, приложение полноценно работает:
// чаты, карта и SOS не зависят от неё.
// ============================================================================

struct ModelInstallView: View {

    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var spec = ModelDownloadSpec.load()
    @State private var confirmCellular = false
    @State private var showImporter = false
    @State private var importStatus: String?
    @State private var isImporting = false

    /// Тик перерисовки статуса профиля после переключения.
    @State private var profileTick = 0
    /// Подтверждение удаления файла модели (UX-проход 06.08).
    @State private var confirmDelete = false
    /// Разбивка занятого места (поручение 06.08): файл помощника —
    /// самый крупный объект приложения, человек должен видеть, что
    /// сколько занимает. Считается в фоне при открытии экрана.
    @State private var storageLines: [(String, String)] = []

    /// Удалить веса и вернуть экран в состояние «модели нет». Профиль
    /// переводится на сетевой честно: локальному отвечать нечем.
    private func deleteModel() {
        for url in ModelStore.installedModels() {
            try? ModelStore.deleteModel(at: url)
        }
        try? LLMModelConfig.remoteDev.saveAsActive()
        Task { await ModelScheduler.shared.invalidateProvider() }
        downloader.refresh(spec: spec)   // состояние экрана — с диска
        profileTick += 1
        Task { await refreshStorage() }  // разбивка места — заново
    }

    /// Мегабайты/гигабайты по-человечески.
    private static func sizeText(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000
            ? String(format: "%.1f ГБ", Double(bytes) / 1_000_000_000)
            : "\(bytes / 1_000_000) МБ"
    }

    /// Разбивка занятого места. Модель и карты — по своим хранилищам,
    /// остальное (переписка, справочники, состояние) — Application
    /// Support целиком; обход дерева — вне главного потока.
    private func refreshStorage() async {
        let modelBytes = ModelStore.installedModels()
            .map(ModelStore.fileSize).reduce(0, +)
        let mapBytes = RegionDownloader.shared.regions
            .compactMap(\.sizeBytes).reduce(0, +)
        let rest: Int64 = await Task.detached(priority: .utility) {
            guard let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first,
                let files = FileManager.default.enumerator(
                    at: support, includingPropertiesForKeys:
                        [.totalFileAllocatedSizeKey]) else { return 0 }
            var total: Int64 = 0
            for case let url as URL in files {
                total += Int64((try? url.resourceValues(forKeys:
                    [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0)
            }
            return total
        }.value
        var lines: [(String, String)] = []
        if modelBytes > 0 {
            lines.append(("Файл помощника", Self.sizeText(modelBytes)))
        }
        if mapBytes > 0 {
            lines.append(("Офлайн-карты", Self.sizeText(mapBytes)))
        }
        // модель лежит в Application Support — вычитаем, чтобы не
        // посчитать её дважды
        let restOnly = max(0, rest - modelBytes)
        if restOnly > 0 {
            lines.append(("Переписка, справочники и настройки",
                          Self.sizeText(restOnly)))
        }
        storageLines = lines
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Локальный помощник")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(RMDesign.textPrimary)
                    Text("\(AppIdentity.assistantName) отвечает целиком на "
                       + "этом телефоне: без интернета, разговоры не "
                       + "покидают устройство. Для этого нужен файл "
                       + "модели\(spec.map { " (\($0.sizeText))" } ?? "").")
                        .font(.system(size: 13.5))
                        .foregroundStyle(RMDesign.textSecondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(RMDesign.surface1)

            Section {
                stateView
            }
            .listRowBackground(RMDesign.surface1)

            if !storageLines.isEmpty {
                Section {
                    ForEach(storageLines, id: \.0) { line in
                        LabeledContent(line.0, value: line.1)
                    }
                } header: {
                    Text("Занятое место")
                        .foregroundStyle(RMDesign.textSecondary)
                }
                .listRowBackground(RMDesign.surface1)
                .foregroundStyle(RMDesign.textPrimary)
            }

            if case .installed = downloader.state {} else {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        if isImporting {
                            HStack {
                                ProgressView()
                                Text("Копирую файл…")
                            }
                        } else {
                            Label("Импортировать файл GGUF (Files)…",
                                  systemImage: "folder")
                        }
                    }
                    .disabled(isImporting)
                    if let importStatus {
                        Text(importStatus)
                            .font(.system(size: 12.5))
                            .foregroundStyle(RMDesign.textSecondary)
                    }
                    Text("Запасной путь: если файл модели уже есть на "
                       + "телефоне или рядом компьютер. Основной путь — "
                       + "кнопка загрузки выше.")
                        .font(.system(size: 12))
                        .foregroundStyle(RMDesign.textTertiary)
                } header: {
                    Text("Запасной путь")
                        .foregroundStyle(RMDesign.textSecondary)
                }
                .listRowBackground(RMDesign.surface1)
            }
        }
        .scrollContentBackground(.hidden)
        .rmScreenBackground()
        .navigationTitle("Помощник")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { downloader.refresh(spec: spec) }
        .task { await refreshStorage() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            importFromFiles(result)
        }
        .confirmationDialog(
            "Wi-Fi сейчас нет. Скачать \(spec?.sizeText ?? "файл") по "
            + "сотовой сети?",
            isPresented: $confirmCellular, titleVisibility: .visible) {
            // необратимое для трафика действие — словами
            Button("Всё равно скачать по сотовой") {
                downloader.start(allowCellular: true)
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch downloader.state {
        case .idle:
            downloadButton(title: "Скачать модель"
                           + (spec.map { " (\($0.sizeText))" } ?? ""))
            Text("По умолчанию — только по Wi-Fi.")
                .font(.system(size: 12))
                .foregroundStyle(RMDesign.textTertiary)

        case .paused(let reason):
            Text(reason)
                .font(.system(size: 13))
                .foregroundStyle(RMDesign.warning)
            downloadButton(title: "Продолжить загрузку")

        case .downloading(let fraction, let bytes, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text("\(bytes / 1_000_000) МБ из \(total / 1_000_000) МБ")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RMDesign.textSecondary)
            }
            Button("Остановить") { downloader.cancel() }
                .foregroundStyle(RMDesign.textSecondary)

        case .verifying:
            HStack {
                ProgressView()
                Text("Проверяю целостность файла (SHA-256)…")
                    .font(.system(size: 13))
                    .foregroundStyle(RMDesign.textSecondary)
            }

        case .installed:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Модель установлена")
                        .foregroundStyle(RMDesign.textPrimary)
                    if let spec {
                        Text("\(spec.displayName) · \(spec.sizeText)")
                            .font(.system(size: 12))
                            .foregroundStyle(RMDesign.textSecondary)
                    }
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(RMDesign.success)
            }
            // Баг 02.08: «модель установлена» ≠ «Софи отвечает локально»:
            // активным мог оставаться сетевой dev-профиль, и гейт Софи
            // честно закрывал чаты. Профиль показывается здесь и
            // переключается одним тапом.
            if ModelScheduler.isLocalProviderActive() {
                Label("Софи отвечает локально (профиль активен)",
                      systemImage: "iphone")
                    .font(.system(size: 13))
                    .foregroundStyle(RMDesign.success)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Активен сетевой профиль: "
                          + LLMModelConfig.loadActive().displayName,
                          systemImage: "wifi.exclamationmark")
                        .font(.system(size: 13))
                        .foregroundStyle(RMDesign.warning)
                    Button("Отвечать локально") {
                        _ = LLMModelConfig.activateLocalIfInstalled()
                        profileTick += 1   // перерисовать статус
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            // UX-проход 06.08: удалить модель было НЕЧЕМ — 2,5 ГБ
            // занимали место без выхода. Удаление обратимо (скачать
            // заново), но дорого по трафику — потому подтверждение.
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Удалить файл и освободить место",
                      systemImage: "trash")
            }
            // последствия — честным списком ДО решения (06.08):
            // что встанет, что продолжит работать
            Text("Без файла перестанут работать: ответы Софи и умное "
               + "сжатие сообщений (тексты будут уходить дословно и "
               + "занимать больше места в радиоэфире), заполнение "
               + "SOS-карточки по описанию.\n"
               + "Продолжат работать: переписка и доставка, карты, "
               + "справочники, SOS вручную. Файл можно скачать заново "
               + "в любой момент.")
                .font(.system(size: 12))
                .foregroundStyle(RMDesign.textTertiary)
            .confirmationDialog("Удалить файл помощника?",
                                isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Удалить \(spec?.sizeText ?? "модель")",
                       role: .destructive) { deleteModel() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Софи перестанет отвечать, а сообщения будут "
                   + "уходить без умного сжатия, пока файл не скачан "
                   + "заново. Переписка и контакты не затрагиваются.")
            }

        case .failed(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(RMDesign.warning)
            downloadButton(title: "Попробовать ещё раз")
        }
    }

    private func downloadButton(title: String) -> some View {
        Button {
            Task {
                if await ModelDownloader.onWiFi() {
                    downloader.start(allowCellular: false)
                } else {
                    // честно спрашиваем ДО расхода сотового трафика
                    confirmCellular = true
                }
            }
        } label: {
            Label(title, systemImage: "arrow.down.circle")
                .font(.system(size: 15, weight: .medium))
        }
        .disabled(spec == nil)
    }

    /// Импорт через Files (запасной путь). Копирование — ВНЕ главного
    /// потока (веса по 2.4 ГБ, синхронная копия вешала интерфейс),
    /// с NSFileCoordinator — файл из iCloud сперва докачивается.
    private func importFromFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let source = urls.first else {
            if case .failure(let error) = result {
                importStatus = "Files не отдал файл: \(error.localizedDescription)"
            }
            return
        }
        isImporting = true
        importStatus = nil
        Task.detached(priority: .userInitiated) {
            let outcome: String
            do {
                let dest = try ModelStore.importModelCoordinated(from: source)
                outcome = "Импортирована \(dest.lastPathComponent) "
                    + "(\(ModelStore.fileSize(dest) / 1_000_000) МБ)"
            } catch {
                outcome = "Импорт не удался: \(error.localizedDescription)"
            }
            await MainActor.run {
                isImporting = false
                importStatus = outcome
                downloader.refresh(spec: spec)
            }
        }
    }
}

#Preview {
    NavigationStack { ModelInstallView() }
        .preferredColorScheme(.dark)
}
