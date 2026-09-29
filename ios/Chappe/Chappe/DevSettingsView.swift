//
//  DevSettingsView.swift
//  R+M — dev-меню: провайдер LLM, импорт моделей, смоук-тест генерации.
//
//  Фаза 1 плана llama_swift_plan.md: переключение remote/local,
//  импорт GGUF через Files, проверка «токены текут, cancel работает».
//

// ВЕСЬ ФАЙЛ — только DEBUG (требование владельца 08.08): экран
// показывает срез личной переписки (статистика оптимизатора),
// и в Release его не должно существовать вовсе, а не прятаться.
#if DEBUG
import SwiftUI
import CryptoKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class DevSettingsModel: ObservableObject {

    @Published var activeConfig = LLMModelConfig.loadActive()
    @Published var models: [URL] = []
    @Published var status: String?
    @Published var isGenerating = false
    @Published var smokeOutput = ""
    @Published var smokeSpeed: Double = 0

    @Published var isBenchRunning = false
    @Published var benchProgress: String?
    @Published var benchShareURL: URL?

    private var smokeTask: Task<Void, Never>?
    private var benchTask: Task<Void, Never>?

    func refresh() {
        ModelStore.adoptDocumentsModels()   // подхватить закинутое в Documents
        activeConfig = LLMModelConfig.loadActive()
        models = ModelStore.installedModels()
    }

    // MARK: Переключение провайдера

    /// Активировать локальный провайдер с выбранным файлом модели.
    func activateLocal(modelFile: String) {
        var config = LLMModelConfig.localQwen
        config.modelFile = modelFile
        config.displayName = "Локально: \(modelFile)"
        saveConfig(config)
    }

    // Адрес Мака (Ф1.3): в UI, не в коде. Хранится в UserDefaults
    // поверх дефолта профиля remoteDev.
    @Published var remoteHost: String = UserDefaults.standard
        .string(forKey: "remote_llm_host")
        ?? LLMModelConfig.remoteDev.host ?? "" {
        didSet {
            UserDefaults.standard.set(remoteHost, forKey: "remote_llm_host")
        }
    }
    @Published var probeResult: String?
    @Published var isProbing = false

    func activateRemote() {
        var config = LLMModelConfig.remoteDev
        config.host = remoteHost.trimmingCharacters(in: .whitespaces)
        saveConfig(config)
    }

    /// «Проверить связь»: реальная ошибка словами, не код LLMError.
    func probeRemote() {
        let host = remoteHost.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: host)?
            .appendingPathComponent("health") else {
            probeResult = "Адрес не похож на URL — нужен вид "
                        + "http://192.168.1.42:8080"
            return
        }
        isProbing = true
        probeResult = nil
        Task {
            defer { isProbing = false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            do {
                let (data, response) = try await URLSession.shared
                    .data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                probeResult = code == 200
                    ? "Связь есть: llama-server отвечает (HTTP 200)"
                    : "Сервер ответил HTTP \(code): "
                      + (String(data: data, encoding: .utf8) ?? "").prefix(120)
            } catch let error as URLError {
                // честная причина + типовые подсказки
                var text = "Нет связи: \(error.localizedDescription)"
                switch error.code {
                case .cannotConnectToHost:
                    text += " — llama-server на Маке не запущен или порт не 8080?"
                case .timedOut, .cannotFindHost, .networkConnectionLost:
                    text += " — проверь, что телефон и Мак в ОДНОЙ Wi-Fi сети"
                default: break
                }
                probeResult = text
            } catch {
                probeResult = "Нет связи: \(error.localizedDescription)"
            }
        }
    }

    private func saveConfig(_ config: LLMModelConfig) {
        do {
            try config.saveAsActive()
            Task { await ModelScheduler.shared.invalidateProvider() }
            status = "Активен: \(config.displayName)"
            refresh()
        } catch {
            status = "Не сохранился конфиг: \(error.localizedDescription)"
        }
    }

    // MARK: Импорт модели из Files

    func importModel(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let source = urls.first else {
            if case .failure(let error) = result {
                status = "Files не отдал файл: \(error.localizedDescription)"
            }
            return
        }
        // Копирование 2.4 ГБ — вне главного потока (Ф1.2): синхронная
        // копия в main вешала интерфейс; координатор докачивает iCloud
        status = "Копирую файл — это может занять минуту…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: String
            do {
                let dest = try ModelStore.importModelCoordinated(from: source)
                outcome = "Импортирована \(dest.lastPathComponent) "
                    + "(\(ModelStore.fileSize(dest) / 1_000_000) МБ)"
            } catch {
                outcome = "Импорт не удался: \(error.localizedDescription)"
            }
            await MainActor.run {
                self?.status = outcome
                self?.refresh()
            }
        }
    }

    // MARK: Смоук-тест: токены текут, cancel работает

    func runSmoke() {
        smokeTask = Task { await smoke() }
    }

    func cancelSmoke() {
        Task { await ModelScheduler.shared.cancelActive() }
        smokeTask?.cancel()
    }

    private func smoke() async {
        isGenerating = true
        smokeOutput = ""
        smokeSpeed = 0
        status = nil
        defer { isGenerating = false }
        do {
            status = "Загружаю модель…"
            _ = try await ModelScheduler.shared.preload()
            status = "Генерирую…"
            let request = LLMRequest(
                prompt: "Ответь по-русски одним абзацем: зачем в походе нужен "
                      + "запас питьевой воды?",
                maxTokens: 200,
                samplingOverride: .extraction)   // temp 0 — воспроизводимо
            // P1: интерактивный дев-запуск (sophie_presence §5)
            let response = try await ModelScheduler.shared.withProvider(.outgoing) {
                try await $0.generate(request)
            }
            smokeOutput = response.text
            smokeSpeed = response.tokensPerSecond
            status = "Готово: \(response.tokensGenerated) токенов, "
                   + "финиш: \(String(describing: response.finishReason))"
        } catch {
            if case LLMError.cancelled = error {
                status = "Отменено (cancel работает)"
            } else {
                status = "Ошибка: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    // MARK: Фаза 2: бенчмарк диктовок и троттлинг

    func runPivotBenchmark() {
        benchTask = Task { await pivotBenchmark() }
    }

    func runThrottleTest() {
        benchTask = Task { await throttleTest() }
    }

    func cancelBench() {
        Task { await ModelScheduler.shared.cancelActive() }
        benchTask?.cancel()
    }

    private func pivotBenchmark() async {
        isBenchRunning = true
        benchShareURL = nil
        benchProgress = "Загружаю модель…"
        defer { isBenchRunning = false }
        do {
            let loadMs = try await ModelScheduler.shared.preload()
            // Весь бенчмарк держит слот одним P1-заходом — прогоны
            // не перемежаются чужими вызовами
            let results = try await ModelScheduler.shared.withProvider(.outgoing) { p in
                try await PivotBenchmark.run(provider: p, loadMs: loadMs) {
                    [weak self] current, total in
                    self?.benchProgress = "Диктовка \(current)/\(total)…"
                }
            }
            benchShareURL = try PivotBenchmark.writeJSON(
                results, name: "ondevice_pivot_bench.json")
            let speeds = results.items.map(\.decodeTokS)
            let avg = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
            benchProgress = String(format: "Готово: %d диктовок · декод в среднем "
                                 + "%.1f tok/s · загрузка %.0f мс · пик RAM %.0f МБ",
                                 results.items.count, avg, loadMs, results.peakRamMb)
        } catch {
            benchProgress = "Ошибка: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// 5 минут непрерывной генерации: tok/s в начале и в конце, пик RAM.
    private func throttleTest() async {
        isBenchRunning = true
        benchShareURL = nil
        benchProgress = "Загружаю модель…"
        defer { isBenchRunning = false }
        do {
            let loadMs = try await ModelScheduler.shared.preload()
            let prompt = "Расскажи подробно, шаг за шагом, как подготовиться "
                       + "к многодневному пешему походу через горный хребет."
            let totalSeconds = 300.0

            // Стресс-тест держит слот одним P1-заходом все 5 минут;
            // данные копятся внутри замыкания и возвращаются кортежем
            let (items, peakRam) = try await ModelScheduler.shared
                .withProvider(.outgoing) { [weak self] p
                    -> ([PivotBenchmark.ItemResult], Double) in
                var items: [PivotBenchmark.ItemResult] = []
                var peakRam = MemoryStats.footprintMB()
                let startedAt = DispatchTime.now()
                while !Task.isCancelled {
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                                         - startedAt.uptimeNanoseconds) / 1e9
                    guard elapsed < totalSeconds else { break }
                    let count = items.count
                    await MainActor.run {
                        self?.benchProgress = String(
                            format: "Троттлинг: %.0f/%.0f с, прогон %d…",
                            elapsed, totalSeconds, count + 1)
                    }
                    let r = try await p.generate(LLMRequest(prompt: prompt,
                                                            maxTokens: 200,
                                                            samplingOverride: .extraction))
                    items.append(.init(ru: "прогон \(items.count + 1)",
                                       pivotRaw: "",
                                       prefillMs: r.prefillMillis,
                                       decodeTokS: r.tokensPerSecond,
                                       tokens: r.tokensGenerated))
                    peakRam = max(peakRam, MemoryStats.footprintMB())
                }
                return (items, peakRam)
            }

            let config = LLMModelConfig.loadActive()
            let results = PivotBenchmark.Results(
                kind: "throttle",
                device: PivotBenchmark.deviceDescription(),
                providerKind: config.providerKind.rawValue,
                modelFile: config.modelFile,
                loadMs: loadMs,
                peakRamMb: peakRam,
                items: items)
            benchShareURL = try PivotBenchmark.writeJSON(
                results, name: "ondevice_throttle.json")
            let first = items.first?.decodeTokS ?? 0
            let last = items.last?.decodeTokS ?? 0
            benchProgress = String(format: "Троттлинг: %d прогонов · старт %.1f → "
                                 + "финиш %.1f tok/s · пик RAM %.0f МБ",
                                 items.count, first, last, peakRam)
        } catch {
            if case LLMError.cancelled = error {
                benchProgress = "Троттлинг прерван."
            } else {
                benchProgress = "Ошибка: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }
}

struct DevSettingsView: View {
    @StateObject private var model = DevSettingsModel()
    @State private var showImporter = false
    @State private var corpusExportResult: String?
    @State private var identityName = Identity.displayName
    @State private var pasteCandidate: Contact?
    @State private var pasteHint: String?
    @ObservedObject private var delivery = DeliveryManager.shared
    @ObservedObject private var relay = RelayTransport.shared
    @State private var meshPeripheralName = UserDefaults.standard
        .string(forKey: "mesh_peripheral_name") ?? ""

    @State private var radioTestHint: String?

    /// Радиотест 02.08: чат «в эфир» на СВОЁМ ключе. Мак не узел
    /// Chappe и содержимое не расшифрует — задача только в том, чтобы
    /// пакет физически ушёл в радио и был пойман приёмником на Маке.
    /// Dev-только: в продуктовом пути такого чата нет.
    /// Метка сборки: без неё «поменялась ли прошивка» проверяется
    /// гаданием (02.08 потеряли на этом полчаса). Дата берётся из
    /// времени сборки бинарника — новее исходников быть не может.
    private var buildStamp: String {
        let url = Bundle.main.executableURL
        let date = (try? url?.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? nil
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        return date.map(formatter.string(from:)) ?? "неизвестно"
    }

    @ViewBuilder
    private var radioTestSection: some View {
        Section("Радиотест (эфир)") {
            LabeledContent("Сборка", value: buildStamp)
            // Парный зонд знакомства телефонов (13.08): вторая точка
            // входа для второго телефона — без launch-аргументов
            if #available(iOS 26.0, *) {
                NavigationLink {
                    AwarePairProbeView()
                } label: {
                    Label("Зонд знакомства телефонов (Wi-Fi)",
                          systemImage: "wifi")
                }
            }
            Button("Создать тестовый чат (мой ключ)") {
                guard let pub = Identity.publicKey() else {
                    radioTestHint = "нет своего ключа — Keychain недоступен"
                    return
                }
                let contact = Contact(
                    id: Identity.fingerprint(of: pub),
                    name: "Эфир (тест)",
                    publicKeyBase64: pub.rawRepresentation.base64EncodedString(),
                    addedAt: Date(), verified: nil)
                ContactStore.upsert(contact)
                radioTestHint = "чат «Эфир (тест)» создан — он в списке чатов"
            }
            // Без этого в эфир пойдёт ТОЛЬКО v1: сессия подтверждается
            // ответом собеседника, а отвечать некому (Мак не узел).
            Button("Перевести тестовый чат на v2 (рэтчет)") {
                guard let pub = Identity.publicKey() else { return }
                let id = Identity.fingerprint(of: pub)
                guard ContactStore.load().contains(where: { $0.id == id })
                else {
                    radioTestHint = "сначала создай тестовый чат"
                    return
                }
                var epoch = RatchetEpoch(seed: Outbox.randomSeed(),
                                         iAmInitiator: true)
                epoch.peerConfirmedV2 = true
                RatchetStore.save(epoch, contactID: id)
                radioTestHint = "следующие сообщения уйдут кодеком 4 (v2)"
            }
            Button("Вернуть тестовый чат на v1") {
                guard let pub = Identity.publicKey() else { return }
                RatchetStore.drop(contactID: Identity.fingerprint(of: pub))
                radioTestHint = "сессия удалена — снова v1 + probe"
            }
            Toggle("Сообщать о прочтении", isOn: Binding(
                get: { DeliveryManager.readReceiptsEnabled },
                set: { DeliveryManager.readReceiptsEnabled = $0 }))
            Text("Собеседник видит, что сообщение прочитано (второе "
               + "время зеленеет). Выключение совместимо: он просто не "
               + "получит отметку.")
                .font(.caption)
                .foregroundStyle(RMDesign.textSecondary)
            if let radioTestHint {
                Text(radioTestHint)
                    .font(.caption)
                    .foregroundStyle(RMDesign.textSecondary)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                radioTestSection
                Section("Активный провайдер") {
                    LabeledContent("Сейчас", value: model.activeConfig.displayName)
                    LabeledContent("Тип", value: model.activeConfig.providerKind.rawValue)
                }
                .listRowBackground(RMDesign.surface1)

                Section {
                    TextField("http://192.168.1.42:8080",
                              text: $model.remoteHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.callout, design: .monospaced))
                    HStack {
                        Button {
                            model.probeRemote()
                        } label: {
                            if model.isProbing {
                                HStack { ProgressView(); Text("Проверяю…") }
                            } else {
                                Label("Проверить связь",
                                      systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                        .disabled(model.isProbing || model.remoteHost.isEmpty)
                        Spacer()
                        Button("Включить remote") { model.activateRemote() }
                            .disabled(model.activeConfig.providerKind == .remote
                                      || model.remoteHost.isEmpty)
                    }
                    if let probe = model.probeResult {
                        Text(probe)
                            .font(.system(size: 12.5))
                            .foregroundStyle(probe.hasPrefix("Связь есть")
                                             ? RMDesign.success : RMDesign.warning)
                            .textSelection(.enabled)
                    }
                    Text("Модель на Маке (llama-server). Телефон и Мак должны "
                       + "быть в одной Wi-Fi сети: по кабелю телефон интернет "
                       + "от Мака не получает. IP Мака: Системные настройки → "
                       + "Wi-Fi → Подробнее.")
                        .font(.system(size: 12))
                        .foregroundStyle(RMDesign.textTertiary)
                } header: {
                    Text("Remote-провайдер (Мак)")
                }
                .listRowBackground(RMDesign.surface1)

                Section("Модели на устройстве") {
                    if model.models.isEmpty {
                        // Основной путь для людей — экран «Помощник»
                        // (загрузка из приложения); Files — запасной
                        NavigationLink {
                            ModelInstallView()
                        } label: {
                            Label("Скачать модель (экран «Помощник»)…",
                                  systemImage: "arrow.down.circle")
                        }
                        Text("Файлов нет. Запасной путь — импорт GGUF "
                           + "через Files (перенести на iPhone: Finder → "
                           + "вкладка Файлы).")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    ForEach(model.models, id: \.self) { url in
                        Button {
                            model.activateLocal(modelFile: url.lastPathComponent)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text("\(ModelStore.fileSize(url) / 1_000_000) МБ")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.activeConfig.providerKind == .local
                                    && model.activeConfig.modelFile == url.lastPathComponent {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            try? ModelStore.deleteModel(at: model.models[i])
                        }
                        model.refresh()
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Импортировать GGUF…", systemImage: "square.and.arrow.down")
                    }
                }
                .listRowBackground(RMDesign.surface1)

                Section("Фаза 2: бенчмарки (llama_swift_plan §2)") {
                    if model.isBenchRunning {
                        HStack {
                            ProgressView()
                            Text(model.benchProgress ?? "…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Стоп") { model.cancelBench() }
                        }
                    } else {
                        Button {
                            model.runPivotBenchmark()
                        } label: {
                            Label("Бенчмарк диктовок (12)", systemImage: "gauge.with.needle")
                        }
                        Button {
                            model.runThrottleTest()
                        } label: {
                            Label("Троттлинг-тест (5 мин)", systemImage: "thermometer.sun")
                        }
                        if let progress = model.benchProgress {
                            Text(progress).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let url = model.benchShareURL {
                        ShareLink(item: url) {
                            Label("Поделиться JSON (AirDrop на Мак)",
                                  systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .listRowBackground(RMDesign.surface1)

                Section {
                    TextField("Имя", text: $identityName)
                        .onSubmit { Identity.displayName = identityName }
                        .onChange(of: identityName) {
                            Identity.displayName = identityName
                        }
                    LabeledContent("ID узла (отпечаток ключа)",
                                   value: Identity.myFingerprint() ?? "ключ недоступен")
                        .font(.system(.callout, design: .monospaced))
                } header: {
                    Text("Как тебя видят")
                } footer: {
                    Text("Пара ключей Curve25519; приватный — в Keychain "
                       + "устройства, в iCloud не уходит. ID — отпечаток "
                       + "публичного ключа.")
                }
                .listRowBackground(RMDesign.surface1)

                Section {
                    // П3б: последние неуверенные сегменты STT
                    if let worst = SpeechDictation.lowConfidenceLog.latest.first {
                        HStack {
                            Text("STT неуверен")
                                .foregroundStyle(RMDesign.textSecondary)
                            Spacer()
                            Text(worst).font(.system(size: 11))
                                .foregroundStyle(RMDesign.warning)
                                .lineLimit(1)
                        }
                    }
                    // Б1: счётчик спасений ленты кэшем — обязан молчать
                    HStack {
                        Text("Лента: спасений кэшем")
                            .foregroundStyle(RMDesign.textSecondary)
                        Spacer()
                        Text("\(HumanChatStore.emptyReadMarkers)")
                            .foregroundStyle(HumanChatStore.emptyReadMarkers == 0
                                             ? RMDesign.success : RMDesign.warning)
                    }
                    // «Рядом» — всегда-параллельный путь (фаза 1,
                    // 07.08), не вид транспорта: строка живёт постоянно
                    HStack {
                        Text("Рядом")
                            .foregroundStyle(RMDesign.textSecondary)
                        Spacer()
                        Text(NearbyTransport.shared.statusLine)
                            .foregroundStyle(RMDesign.textPrimary)
                            .font(.system(size: 12))
                    }
                    if delivery.transportKind == "mesh",
                       let mesh = delivery.meshLink {
                        HStack {
                            Text("Дальняя связь")
                                .foregroundStyle(RMDesign.textSecondary)
                            Spacer()
                            Text(mesh.stateLine
                                 + (mesh.queuedForAirtime > 0
                                    ? " · в очереди: \(mesh.queuedForAirtime)"
                                    : ""))
                                .foregroundStyle(RMDesign.textPrimary)
                                .font(.system(size: 12))
                        }
                        LabeledContent("Регион", value: mesh.config.region)
                            .font(.system(.callout, design: .monospaced))
                        // мок ↔ живое радио: именем, не пересборкой
                        TextField("Имя радио (пусто — любое)",
                                  text: $meshPeripheralName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit {
                                UserDefaults.standard.set(
                                    meshPeripheralName,
                                    forKey: "mesh_peripheral_name")
                                delivery.transportKind = "demo"
                                delivery.restart()
                                delivery.transportKind = "mesh"
                                delivery.restart()
                            }
                    }
                    Picker("Транспорт", selection: $delivery.transportKind) {
                        Text("Демо (нет узлов)").tag("demo")
                        Text("LAN (Wi-Fi)").tag("lan")
                        Text("Дальняя связь (радио)").tag("mesh")
                    }
                    if delivery.transportKind == "lan" {
                        TextField("IP собеседника", text: $delivery.peerHost)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                        LabeledContent("Мой IP",
                                       value: NetInfo.myIPv4() ?? "нет сети")
                            .font(.system(.callout, design: .monospaced))
                        LabeledContent("Узлов", value: "\(delivery.nodeCount)")
                        Button {
                            DeliveryManager.shared.restart()
                            DeliveryManager.shared.pushQueue()
                        } label: {
                            Label("Переподключить и дослать очередь",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                } header: {
                    Text("Транспорт")
                } footer: {
                    Text("LAN шлёт только готовые envelope-блобы — плейнтекста "
                       + "на проводе нет, это репетиция LoRa. Порт 47474.")
                }
                .listRowBackground(RMDesign.surface1)

                Section {
                    Toggle("Включена", isOn: Binding(
                        get: { relay.enabled },
                        set: { RelayTransport.setEnabled($0) }))
                    TextField("Адрес релея", text: $relay.urlString)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                    LabeledContent("Интернет",
                                   value: relay.internetUp ? "есть" : "нет")
                    // пульс наблюдателя (правило 3): опросы видимы
                    LabeledContent("Пульс", value: relay.pulse)
                        .font(.system(size: 12, design: .monospaced))
                    Button {
                        DeliveryManager.shared.pushQueue()
                        Task {
                            await RelayTransport.shared.pollInbox()
                            await RelayTransport.shared.pollStoredOutcomes()
                        }
                    } label: {
                        Label("Опросить релей сейчас",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                } header: {
                    Text("Интернет-доставка (релей)")
                } footer: {
                    Text("Для местного испытания: адрес вида "
                       + "http://192.168.x.x:8443 (relayd на Маке). "
                       + "Ключ личности релею не предъявляется — только "
                       + "box-ключ эпохи.")
                }
                .listRowBackground(RMDesign.surface1)

                Section {
                    // Симулятор без камеры: тот же payload, что в QR
                    Button {
                        if let payload = UIPasteboard.general.string,
                           let contact = ContactStore.parse(payload) {
                            pasteCandidate = contact
                        } else {
                            pasteHint = "В буфере нет контакта \(AppIdentity.appName) (base64)"
                        }
                    } label: {
                        Label("Вставить контакт из буфера",
                              systemImage: "doc.on.clipboard")
                    }
                    if let hint = pasteHint {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(RMDesign.warning)
                    }
                } header: {
                    Text("Контакты")
                }
                .listRowBackground(RMDesign.surface1)

                Section("Словарь") {
                    NavigationLink {
                        ResidualStatsView()
                    } label: {
                        Label("Словарь · пропуски", systemImage: "text.badge.plus")
                    }
                    NavigationLink {
                        OptimizerStatsView()
                    } label: {
                        Label("Словарь · что сокращает оптимизатор",
                              systemImage: "scissors")
                    }
                }
                .listRowBackground(RMDesign.surface1)

                Section("Диктовка") {
                    NavigationLink {
                        DictationDebugView()
                    } label: {
                        Label("Диктовка · отладка", systemImage: "waveform")
                    }
                    // Авто-корпус (п.3, 31.07): каждая диктовка уже
                    // фикстура; выгрузка целиком в Files → Chappe
                    Button {
                        do {
                            let n = try DictationCorpus.exportAll()
                            corpusExportResult = "Выгружено записей: \(n) — "
                                + "Files → Chappe → dictation_corpus_export"
                        } catch {
                            corpusExportResult = "Не вышло: \(error.localizedDescription)"
                        }
                    } label: {
                        Label("Корпус диктовок: выгрузить всё "
                              + "(\(DictationCorpus.load().count) зап.)",
                              systemImage: "square.and.arrow.up.on.square")
                    }
                    if let corpusExportResult {
                        Text(corpusExportResult)
                            .font(.caption)
                            .foregroundStyle(RMDesign.textSecondary)
                    }
                }
                .listRowBackground(RMDesign.surface1)

                // Пикер «Разворот кодов» переехал в обычные Настройки
                // (поручение владельца 06.08) — SettingsRootView.
                .listRowBackground(RMDesign.surface1)

                Section("Смоук-тест генерации") {
                    if model.isGenerating {
                        HStack {
                            ProgressView()
                            Text(model.status ?? "…")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Отмена") { model.cancelSmoke() }
                        }
                    } else {
                        Button {
                            model.runSmoke()
                        } label: {
                            Label("Сгенерировать (temp 0)", systemImage: "play.fill")
                        }
                        if let status = model.status {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !model.smokeOutput.isEmpty {
                        Text(model.smokeOutput)
                            .font(.callout)
                            .textSelection(.enabled)
                        if model.smokeSpeed > 0 {
                            LabeledContent("Скорость",
                                           value: String(format: "%.1f tok/s", model.smokeSpeed))
                        }
                    }
                }
                .listRowBackground(RMDesign.surface1)
            }
            .rmScreenBackground()
            .navigationTitle("Dev · LLM")
            // Правка 31.07: после клавиатуры (поле адреса Мака) у Form
            // оставался фантомный нижний inset — список «уезжал» выше
            // экрана и застревал. Интерактивное скрытие клавиатуры
            // убирает inset вместе с ней; пустой safeAreaInset удалён.
            .scrollDismissesKeyboard(.interactively)
            .onAppear { model.refresh() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                model.importModel(result: result)
            }
            .sheet(item: $pasteCandidate) { candidate in
                ContactConfirmSheet(contact: candidate,
                                    onConfirm: {
                                        // тот же гейт смены ключа, что в
                                        // основном UI (WP1): молча нельзя
                                        switch ContactStore.upsertGuarded(candidate) {
                                        case .saved:
                                            pasteHint = "Добавлен: \(candidate.name)"
                                        case .keyChangeSuspected(let existing, _):
                                            pasteHint = "ОТКАЗ: имя «\(existing.name)» уже "
                                                + "есть с другим ключом (\(existing.id)) — "
                                                + "возможна подмена. Принять новый ключ "
                                                + "можно только из списка чатов."
                                        }
                                        pasteCandidate = nil
                                    },
                                    onCancel: { pasteCandidate = nil })
                    .presentationDetents([.medium])
            }
        }
    }
}

#Preview {
    DevSettingsView()
}

// MARK: - Словарь · пропуски (residual-счётчик)

/// Топ непокрытых словарём слов по подтверждённым отправкам —
/// кандидаты в словарь при следующей итерации (semantic_compression §6).
struct ResidualStatsView: View {
    @State private var top: [(word: String, count: Int)] = []
    @State private var exportURL: URL?
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                if top.isEmpty {
                    Text("Пока пусто: счётчик копится с подтверждённых "
                       + "семантических отправок. Имена и числа не считаются.")
                        .foregroundStyle(RMDesign.textSecondary)
                        .font(.callout)
                }
                ForEach(top, id: \.word) { item in
                    LabeledContent(item.word, value: "\(item.count)")
                        .font(.system(.body, design: .monospaced))
                }
            } footer: {
                Text("Локальная словарная телеметрия — никуда не передаётся. "
                   + "Экспорт только вручную.")
            }
            .listRowBackground(RMDesign.surface1)

            Section {
                Button {
                    exportURL = try? ResidualCounter.exportJSON()
                } label: {
                    Label("Экспорт JSON", systemImage: "square.and.arrow.up")
                }
                if let url = exportURL {
                    ShareLink(item: url) {
                        Label("Поделиться экспортом", systemImage: "paperplane")
                    }
                }
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Обнулить", systemImage: "trash")
                }
            }
            .listRowBackground(RMDesign.surface1)
        }
        .rmScreenBackground()
        .navigationTitle("Словарь · пропуски")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { top = ResidualCounter.top() }
        .confirmationDialog("Обнулить счётчик пропусков?",
                            isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Обнулить", role: .destructive) {
                ResidualCounter.reset()
                top = []
                exportURL = nil
            }
        }
    }
}

// MARK: - Диктовка · отладка

/// Debug-лог последней диктовки: длительность, путь распознавания,
/// чанки с границами и длинами, итог склейки; тумблер хранения записи.
struct DictationDebugView: View {
    @State private var log = DictationDebugLog.load()
    @State private var keepRecording = SpeechDictation.keepLastRecording

    var body: some View {
        List {
            Section("Последняя диктовка") {
                if let log {
                    LabeledContent("Когда",
                                   value: log.date.formatted(date: .omitted,
                                                             time: .standard))
                    LabeledContent("Длительность файла",
                                   value: String(format: "%.1f с", log.fileDuration))
                    LabeledContent("Путь", value: log.path)
                    if let coverage = log.wholeCoverage {
                        LabeledContent("Покрытие целого",
                                       value: String(format: "%.0f%%", coverage * 100))
                    }
                    LabeledContent("Итог склейки",
                                   value: "\(log.joinedLength) симв.")
                } else {
                    Text("Диктовок ещё не было.")
                        .foregroundStyle(RMDesign.textSecondary)
                }
            }
            .listRowBackground(RMDesign.surface1)

            if let stages = log?.stages, !stages.isEmpty {
                Section("Стадии") {
                    ForEach(stages.indices, id: \.self) { i in
                        LabeledContent(stages[i].name,
                                       value: Self.timestamp(stages[i].at))
                            .font(.system(size: 12.5, design: .monospaced))
                    }
                }
                .listRowBackground(RMDesign.surface1)
            }

            if let chunks = log?.chunks, !chunks.isEmpty {
                Section("Чанки") {
                    ForEach(chunks.indices, id: \.self) { i in
                        let c = chunks[i]
                        LabeledContent(String(format: "%.1f–%.1f с",
                                              c.start, c.end)) {
                            Text(c.failed ? "ОТКАЗ"
                                 : "\(c.textLength) симв."
                                   + (c.retried ? " · повтор" : ""))
                                .foregroundStyle(c.failed ? RMDesign.danger
                                                          : RMDesign.textPrimary)
                        }
                        .font(.system(.callout, design: .monospaced))
                    }
                }
                .listRowBackground(RMDesign.surface1)
            }

            Section {
                Toggle("Хранить последнюю запись для отладки",
                       isOn: $keepRecording)
                    .onChange(of: keepRecording) {
                        SpeechDictation.keepLastRecording = keepRecording
                    }
                if keepRecording {
                    Text("Файл: tmp/last_dictation.m4a — перезаписывается "
                       + "каждой диктовкой. Выключи после отладки: аудио "
                       + "храниться не должно.")
                        .font(.system(size: 12))
                        .foregroundStyle(RMDesign.warning)
                }
            }
            .listRowBackground(RMDesign.surface1)
        }
        .rmScreenBackground()
        .navigationTitle("Диктовка · отладка")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { log = DictationDebugLog.load() }
        .onAppear { log = DictationDebugLog.load() }
    }

    /// Полный таймстемп стадии: ЧЧ:ММ:СС.ммм.
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}

/// Что оптимизатор чаще всего убирает — прямой список кандидатов в
/// словарь Smysl. ЭКРАН ТОЛЬКО DEBUG (весь файл под #if DEBUG): это
/// слова из личной переписки, в Release их показывать негде и нечем.
struct OptimizerStatsView: View {
    @State private var rows: [(word: String, count: Int)] = []

    var body: some View {
        List {
            if rows.isEmpty {
                Text("Пока пусто: оптимизатор ещё не сокращал сообщения.")
                    .foregroundStyle(RMDesign.textSecondary)
                    .listRowBackground(RMDesign.surface1)
            }
            ForEach(rows, id: \.word) { row in
                HStack {
                    Text(row.word)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("\(row.count)")
                        .foregroundStyle(RMDesign.textSecondary)
                }
                .listRowBackground(RMDesign.surface1)
            }
            if !rows.isEmpty {
                Button(role: .destructive) {
                    OptimizerStats.reset()
                    rows = []
                } label: {
                    Label("Очистить", systemImage: "trash")
                }
                .listRowBackground(RMDesign.surface1)
            }
        }
        .scrollContentBackground(.hidden)
        .rmScreenBackground()
        .navigationTitle("Что сокращает оптимизатор")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { rows = OptimizerStats.top(40) }
    }
}

#endif
