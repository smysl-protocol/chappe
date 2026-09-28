//
//  ContentView.swift
//  Chappe — корневой таббар + диагностика радиоузла.
//
//  BLECheckView (бриф 02.08): от сканера — к соединению. Список только
//  узлов (фильтр по сервису), тап → подключение → сопряжение → факты
//  узла. В UI ни «LoRa», ни «mesh» — только «узел» и «радио».
//
//  ВАЖНО: в симуляторе iPhone Bluetooth отсутствует физически.
//  Запускать только на настоящем телефоне.
//

import SwiftUI
import CoreBluetooth
import Combine

/// Вкладки приложения; роутер позволяет переключать их программно
/// (гейт-плашка Софи ведёт во вкладку Dev по мокапу sophie_local_only_gate).
enum AppTab: Hashable {
    case chat, sophie, map, settings
}

@MainActor
final class TabRouter: ObservableObject {
    // Дом — чаты: ежедневный вход (задание 30.07).
    @Published var selection: AppTab = .chat
}

/// WP0 (02.08): стекло таб-бара сэмплирует контент — над светлой
/// картой бар становился светлым (и мог залипать на соседних вкладках).
/// Тёмная схема бара задаётся ЛОКАЛЬНО содержимому вкладок этого
/// TabView (на iOS 26 модификаторы бара живут на контенте) — никаких
/// UITabBar.appearance() и окна.
private extension View {
    func darkTabBar() -> some View {
        self.toolbarColorScheme(.dark, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }
}

/// Корневой экран: таббар приложения.
struct ContentView: View {
    @StateObject private var router = TabRouter()
    /// Каждый принятый пакет тикает eventCounter — бейдж «Чаты»
    /// пересчитывается живьём, а не при заходе на вкладку (блок 6, 10.08).
    @ObservedObject private var delivery = DeliveryManager.shared

    #if DEBUG
    /// dev: --probe-aware-pair — парный зонд знакомства телефонов
    /// (полевой прогон 13.08; вторая точка входа — Dev-настройки)
    @State private var showAwarePairProbe = ProcessInfo.processInfo
        .arguments.contains("--probe-aware-pair")
    #endif

    /// Первый запуск: предложить своё имя (мега-1, 14.08). Отказ
    /// уважается — остаётся «Без имени», сменить можно в Настройках
    /// и тапом по имени на «Моём QR».
    @State private var askName = false
    @State private var nameDraft = ""

    /// Сумма непрочитанных по всем чатам — бейдж вкладки «Чаты».
    private var totalUnread: Int {
        _ = delivery.eventCounter   // зависимость: пересчёт на приём
        return ContactStore.load()
            .map { HumanChatStore.unreadCount(contactID: $0.id) }
            .reduce(0, +)
    }

    var body: some View {
        // Таббар (задание 30.07): Чаты · Софи · Карта · Настройки.
        // Чаты первыми — ежедневный вход. Софи — отдельная вкладка;
        // её чаты и чаты с людьми НЕ смешиваются в одном списке
        // (тест ChatSeparationTests). SOS-вкладки нет: вход в SOS —
        // первый закреплённый чат Софи; служебные экраны — в Настройках.
        // Tab(_:systemImage:value:) вместо устаревшего .tabItem (iOS 18+).
        TabView(selection: $router.selection) {
            Tab("Чаты", systemImage: "message", value: AppTab.chat) {
                ChatListView()
                    .darkTabBar()
            }
            .badge(totalUnread)   // 0 система прячет сама
            Tab(AppIdentity.assistantName, systemImage: "sparkle",
                value: AppTab.sophie) {
                SophieHomeView(standalone: true)
                    .darkTabBar()
            }
            // Карта — не стартовый экран (дом — чаты). Задел под «полевой
            // режим» со стартом с карты — отдельное решение, не v1.
            Tab("Карта", systemImage: "map", value: AppTab.map) {
                MapScreen()
                    .darkTabBar()
            }
            // ползунки, не шестерёнка (бриф: шестерёнка конфликтует
            // с иконкой на карте)
            Tab("Настройки", systemImage: "slider.horizontal.3",
                value: AppTab.settings) {
                SettingsRootView()
                    .darkTabBar()
            }
        }
        .environmentObject(router)
        // Баннер знакомства (08.08) — поверх любой вкладки: сосед
        // объявил карточку, человек отвечает одним нажатием. Логика
        #if DEBUG
        .fullScreenCover(isPresented: $showAwarePairProbe) {
            if #available(iOS 26.0, *) {
                AwarePairProbeView()
            } else {
                Text("нужен iOS 26").padding()
            }
        }
        #endif
        // Глобальная тема (design/sophie/design_tokens.md): тема одна,
        // тёмная; нейтральный акцент приложения — не синий Софи
        .tint(RMDesign.accent)
        .preferredColorScheme(.dark)
        // имя спрашивается один раз; пустой ввод = «Без имени», без
        // навязывания (сменить можно в Настройках и на «Моём QR»)
        .alert("Как вас называть?", isPresented: $askName) {
            TextField("Ваше имя", text: $nameDraft)
            Button("Сохранить") {
                Identity.displayName = nameDraft
            }
            Button("Позже", role: .cancel) {}
        } message: {
            Text("Имя увидят собеседники при знакомстве. "
               + "Без имени вы будете «Без имени».")
        }
        .onAppear {
            if !Identity.hasCustomName,
               !UserDefaults.standard.bool(forKey: Identity.namePromptedKey) {
                UserDefaults.standard.set(true, forKey: Identity.namePromptedKey)
                askName = true
            }
            // уведомления о входящих (фон — ядро, 10.08): разрешение
            // спрашивается при старте, отказ уважается молча
            IncomingNotifier.requestAuthorizationOnce()
            // Dev-хуки — только DEBUG (подача 06.08): в TestFlight/AppStore
            // сборке launch-аргументы не читаются вовсе
            #if DEBUG
            // dev: --open-tab chat|sophie|map|settings — прогоны и
            // скриншоты вкладок без рук (как --open-contact)
            let args = ProcessInfo.processInfo.arguments
            // dev: светлая карта с запуска — репро бага таб-бара (WP0)
            if args.contains("--map-style-light") {
                MapConfig.styleMode = "light"
            }
            if let index = args.firstIndex(of: "--open-tab"),
               args.indices.contains(index + 1) {
                switch args[index + 1] {
                case "sophie": router.selection = .sophie
                case "map": router.selection = .map
                case "settings": router.selection = .settings
                default: router.selection = .chat
                }
            }
            // dev: релейное испытание без рук (05.08, тот же приём,
            // что --open-tab): адрес релея, контакт, отправка
            if let index = args.firstIndex(of: "--relay-url"),
               args.indices.contains(index + 1) {
                RelayTransport.shared.urlString = args[index + 1]
                RelayTransport.shared.enabled = true
            }
            var devContactID: String?
            if let index = args.firstIndex(of: "--add-contact"),
               args.indices.contains(index + 1),
               let contact = ContactStore.parse(args[index + 1]) {
                _ = ContactStore.upsert(contact)
                devContactID = contact.id
                print("[dev] контакт добавлен: \(contact.name)")
            }
            if let index = args.firstIndex(of: "--relay-send"),
               args.indices.contains(index + 1) {
                let text = args[index + 1]
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    // адресат — контакт из --add-contact, не «первый
                    // попавшийся»: у владельца есть контакт «Эфир» на
                    // собственном ключе, отправка ему замыкается на себя
                    let contacts = ContactStore.load()
                    guard let contact = devContactID
                        .flatMap({ id in contacts.first { $0.id == id } })
                        ?? contacts.first else {
                        print("[dev] --relay-send: контактов нет")
                        return
                    }
                    var entry = ChatEntry(kind: .outgoing, text: text,
                                          status: "отправляется…")
                    HumanChatStore.upsertLog(entry, contactID: contact.id)
                    do {
                        // гейт размера: store против zlib
                        let (codec, data) = TextCodec.best(text)
                        let queued = try Outbox.enqueueSealed(
                            innerCodec: codec,
                            data: data, to: contact,
                            entryID: entry.id)
                        entry.wireMsgID = Int(queued.msgID)
                        HumanChatStore.upsertLog(entry, contactID: contact.id)
                        print("[dev] в очередь: msgID \(queued.msgID), "
                              + "\(queued.totalBytes) Б")
                        DeliveryManager.shared.pushQueue()
                    } catch {
                        print("[dev] не закодировалось: \(error)")
                    }
                }
            }
            #endif
        }
    }
}

struct BLECheckView: View {
    // WP2 (02.08): соединение живёт в NodeProbe.shared на уровне
    // приложения — экран только отображает. Раньше @StateObject +
    // onDisappear.stop() рвали связь при каждом уходе с экрана, и
    // каждый вход сканировал и сопрягался заново.
    @ObservedObject private var probe = NodeProbe.shared
    /// НЕ @ObservedObject (мега-14, 14.08): eventCounter тикает на
    /// КАЖДЫЙ принятый пакет (~2 с на живом радио) и перестраивал весь
    /// экран настроек радио — тапы глохли в перерисовке (корень
    /// мёртвой кнопки региона), батарея грелась. Живые строки статуса
    /// обновляет свой TimelineView (yieldedInfo), остальному экрану
    /// пульс пакетов не нужен.
    private var delivery: DeliveryManager { .shared }

    /// Обзор эфира при отданном узле: другие устройства + смена
    /// (просьба владельца 10.08). Пассивный скан, не подключается.
    @StateObject private var overview = RadioOverviewScanner()

    /// Переход к смене региона — СОСТОЯНИЕМ, не NavigationLink (полевое
    /// 13.08: при живом радио eventCounter тикает каждые ~2 с, List
    /// перерисовывается, и тап по view-destination NavigationLink
    /// попадал в перестройку — пуш молча глох. State-driven пуш
    /// переживает перерисовки; в тихом симуляторе оба пути работали,
    /// мёртвый тап жил только на живом канале.
    @State private var showRegionChange = false

    var body: some View {
        List {
            // Видимость секций — ТОЛЬКО по манифесту (замок A, 11.08):
            // регресс был «facts загейчены в .ready, в рабочей .yielded
            // не показывались». Тело больше не хардкодит фазы —
            // спрашивает единую правду SettingsManifest.
            statusSection
            if reachable("radio.devices") { devicesSection }
            if reachable("radio.nearby") { switchSection }
            if reachable("radio.facts") { factsSection }
            if reachable("radio.reconnect") { reconnectSection }
        }
        .scrollContentBackground(.hidden)
        .rmScreenBackground()
        .navigationTitle("Радиоустройства (LoRa)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showRegionChange) {
            RegionChangeView()
        }
        .onAppear { probe.startIfNeeded() }
        .onChange(of: probe.phase == .yielded, initial: true) { _, yielded in
            if yielded { overview.start() } else { overview.stop() }
        }
        .onDisappear { overview.stop() }
    }

    /// Достижим ли раздел радиоэкрана в текущей фазе — по манифесту.
    private func reachable(_ id: String) -> Bool {
        SettingsManifest.radioSectionReachable(id, in: probe.phase)
    }

    /// Факты для показа: в фазе пробы .ready — живые от пробы; в рабочей
    /// .yielded проба отдала узел транспорту — берём ЖИВЫЕ факты самого
    /// линка (он читает тот же конфиг-дамп, 13.08: раньше здесь был
    /// только кэш реестра, и при пустом кэше профиль показывал «Имя —,
    /// Страна —» при работающем радиоканале); кэш реестра — запасной.
    private var activeFacts: NodeProbe.NodeFacts {
        if probe.phase == .yielded,
           probe.facts.longName == nil, probe.facts.region == nil {
            if let live = delivery.meshLink?.liveFacts,
               live.longName != nil || live.region != nil {
                return live
            }
            if let known = NodeRegistry.load().values
                .max(by: { $0.lastSeen < $1.lastSeen }) {
                var f = NodeProbe.NodeFacts()
                f.longName = known.name
                f.region = known.region
                f.nodeCount = known.nodeCount ?? 0
                return f
            }
        }
        return probe.facts
    }

    /// Кнопка переподключения в рабочем состоянии (.yielded): пересоздать
    /// линк транспорта к текущему узлу. В reconnecting/failed своя кнопка
    /// живёт в statusSection.
    @ViewBuilder
    private var reconnectSection: some View {
        Section {
            Button {
                if let name = DeliveryManager.shared.meshLink?.attachedNodeName
                    ?? NodeRegistry.load().values
                        .max(by: { $0.lastSeen < $1.lastSeen })?.name {
                    DeliveryManager.shared.switchRadioDevice(named: name)
                }
            } label: {
                Label("Переподключить устройство",
                      systemImage: "arrow.clockwise")
                    .foregroundStyle(RMDesign.accentLight)
            }
            .accessibilityIdentifier("radio.reconnect.button")
        }
        .listRowBackground(RMDesign.surface1)
        .accessibilityIdentifier("radio.reconnect")
    }

    /// Информация по текущему подключению дальней связи: имя узла,
    /// ЧЕСТНАЯ живость линка (блок 3: «подключено» только на живом),
    /// счётчики отказов и очереди.
    @ViewBuilder
    private var yieldedInfo: some View {
        let mesh = DeliveryManager.shared.meshLink
        VStack(alignment: .leading, spacing: 6) {
            if mesh?.isLinkUp == true {
                Label("Дальняя связь работает через: " + yieldedDeviceName,
                      systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(RMDesign.success)
            } else {
                // мёртвый линк не смеет выглядеть подключённым
                // (полевой случай 09.08: BLE передёрнули — апп врал
                // «подключён», а слал в пустоту)
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Переподключаюсь к устройству…")
                        .foregroundStyle(RMDesign.warning)
                }
            }
            if let line = mesh?.stateLine {
                Text("Состояние: \(line)")
                    .font(.caption)
                    .foregroundStyle(RMDesign.textSecondary)
            }
            if let mesh {
                Text("Отказов записи: \(mesh.writeFailures) · "
                     + "в очереди эфира: \(mesh.queuedForAirtime)")
                    .font(.caption)
                    .foregroundStyle(RMDesign.textTertiary)
            }
        }
    }

    /// Узел — текущий? По имени-фильтру настройки (или по живому
    /// линку): attachedNodeName один ненадёжен — при пересоздании
    /// линка он пуст, и текущий узел показывался как «другой» с
    /// кнопкой «сменить» (полевой скрин 10.08).
    private func isCurrentDevice(_ name: String) -> Bool {
        if DeliveryManager.shared.meshLink?.attachedNodeName == name {
            return true
        }
        let filter = UserDefaults.standard
            .string(forKey: "mesh_peripheral_name") ?? ""
        return !filter.isEmpty
            && name.lowercased().contains(filter.lowercased())
    }

    /// Другие устройства рядом + смена узла по тапу. Смена — это
    /// имя-фильтр настройкой и пересоздание линка; связь переезжает
    /// сама, без перезагрузок узлов.
    @ViewBuilder
    private var switchSection: some View {
        Section("Другие устройства рядом: \(overview.seen.count)") {
            if overview.seen.isEmpty {
                Text(overview.scanning
                     ? "Смотрю эфир… Устройство, подключённое к другому "
                     + "телефону, в эфире не видно — отключите его там "
                     + "или включите свободное рядом."
                     : "Bluetooth недоступен для обзора")
                    .font(.caption)
                    .foregroundStyle(RMDesign.textSecondary)
            }
            ForEach(overview.seen) { item in
                Button {
                    DeliveryManager.shared.switchRadioDevice(named: item.name)
                } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(RMDesign.accentLight)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .foregroundStyle(RMDesign.textPrimary)
                            Text(signalText(item.rssi))
                                .font(.caption)
                                .foregroundStyle(RMDesign.textSecondary)
                        }
                        Spacer()
                        if isCurrentDevice(item.name) {
                            Text("текущее")
                                .font(.caption)
                                .foregroundStyle(RMDesign.success)
                        } else {
                            Text("сменить")
                                .font(.caption)
                                .foregroundStyle(RMDesign.accentLight)
                        }
                    }
                }
                .disabled(isCurrentDevice(item.name))
            }
        }
        .listRowBackground(RMDesign.surface1)
        .accessibilityIdentifier("radio.nearby")
    }

    // MARK: Состояние — всегда видно, что происходит

    @ViewBuilder
    private var statusSection: some View {
        Section("Состояние") {
            statusBody
        }
        .listRowBackground(RMDesign.surface1)
        .accessibilityIdentifier("radio.status")
    }

    @ViewBuilder
    private var statusBody: some View {
        Group {
            switch probe.phase {
            case .idle:
                Text("Готов к поиску")
            case .bluetoothOff:
                Label("Bluetooth выключен — включите в Пункте управления",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(RMDesign.warning)
            case .scanning:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Ищу устройства поблизости…")
                }
            case .connecting(let name):
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Подключаюсь к «\(name)»…")
                }
            case .pairing:
                // Ожидание кода — видимое состояние, не «зависание»
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Сопряжение…").fontWeight(.medium)
                    }
                    Text("Если устройство показывает код на своём экране — "
                       + "введите его в диалоге, который откроет система")
                        .font(.caption)
                        .foregroundStyle(RMDesign.textSecondary)
                }
            case .handshake:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Читаю данные устройства…")
                }
            case .ready:
                Label("Устройство подключено", systemImage: "checkmark.circle")
                    .foregroundStyle(RMDesign.success)
            case .yielded:
                // НЕ ошибка: узел отдан дальней связи — так и задумано.
                // 06.08 (находка владельца): экран молчал пустотой.
                // 10.08 (просьба владельца): вернуть ИНФОРМАЦИЮ по
                // текущему подключению — имя, честная живость линка
                // (не «подключён» на мёртвом), счётчики; строка
                // обновляется по таймеру: MeshtasticLink — не
                // ObservableObject
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    yieldedInfo
                }
            case .reconnecting:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Устройство пропало — жду его обратно…")
                            .fontWeight(.medium)
                    }
                    Text("Подключусь сам, как только устройство появится "
                       + "рядом. Можно начать новый поиск.")
                        .font(.caption)
                        .foregroundStyle(RMDesign.textSecondary)
                    Button("Искать заново") { probe.startScan() }
                        .font(.callout)
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Label(reason, systemImage: "xmark.octagon")
                        .foregroundStyle(RMDesign.danger)
                    Button("Попробовать ещё раз") { probe.startScan() }
                }
            }
        }
    }

    // MARK: Найденные узлы — только наши (фильтр по сервису в скане)

    @ViewBuilder
    private var devicesSection: some View {
        Section("Устройства поблизости: \(probe.found.count)") {
            if probe.found.isEmpty {
                Text("Пока никого — устройство включено и рядом?")
                    .foregroundStyle(RMDesign.textSecondary)
            }
            ForEach(probe.found) { item in
                Button {
                    probe.connect(item)
                } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(RMDesign.accentLight)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .foregroundStyle(RMDesign.textPrimary)
                            Text(signalText(item.rssi))
                                .font(.caption)
                                .foregroundStyle(RMDesign.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(RMDesign.textTertiary)
                    }
                }
            }
        }
        .listRowBackground(RMDesign.surface1)
        .accessibilityIdentifier("radio.devices")
    }

    // MARK: Факты узла — результат, а не «подключено»

    @ViewBuilder
    private var factsSection: some View {
        // WP0: расхождение регионов — громко и первым, не молчание.
        // UX-проход 06.08: рядом с предупреждением — действие; сама
        // смена — отдельным экраном с подтверждением (частоты = закон)
        if !probe.regionWarnings.isEmpty {
            Section {
                ForEach(probe.regionWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(RMDesign.warning)
                        .font(.callout)
                }
                Button {
                    showRegionChange = true
                } label: {
                    Label("Сменить страну и частоты",
                          systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(RMDesign.accentLight)
                }
            }
            .listRowBackground(RMDesign.surface1)
            .accessibilityIdentifier("radio.regionWarning")
        }
        Section("Устройство") {
            let f = activeFacts
            factRow("Имя", f.longName ?? "—")
            // firmware/лимит проба читает вживую; в .yielded (кэш) их нет
            if let firmware = f.firmware {
                factRow("Прошивка", firmware)
            }
            Button {
                showRegionChange = true
            } label: {
                HStack {
                    factRow("Страна и частоты", f.region ?? "—")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RMDesign.textTertiary)
                }
            }
            .accessibilityIdentifier("radio.facts.regionLink")
            factRow("Видит устройств", "\(f.nodeCount)")
            if let limit = f.writeLimit {
                factRow("Пакет за запись", "\(limit) Б")
            }
            // «Использовать для связи» — только в фазе пробы .ready:
            // проба проверила устройство, человек забирает его под
            // транспорт. В .yielded устройство уже в связи — там кнопка
            // переподключения (reconnectSection).
            if probe.phase == .ready {
                Button {
                    if let name = f.longName {
                        DeliveryManager.shared.switchRadioDevice(named: name)
                    }
                } label: {
                    Label("Использовать для связи",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(RMDesign.accentLight)
                }
                .disabled(f.longName == nil)
            }
        }
        .listRowBackground(RMDesign.surface1)
        .accessibilityIdentifier("radio.facts")
    }

    /// Имя устройства, которым занята дальняя связь: живое имя от
    /// транспорта, иначе последнее известное из реестра.
    private var yieldedDeviceName: String {
        if let name = DeliveryManager.shared.meshLink?.attachedNodeName {
            return "«\(name)»"
        }
        if let known = NodeRegistry.load().values
            .max(by: { $0.lastSeen < $1.lastSeen })?.name {
            return "«\(known)» (последнее известное)"
        }
        return "радиоустройство"
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(RMDesign.textSecondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }

    private func signalText(_ rssi: Int) -> String {
        switch rssi {
        case (-55)...: "сигнал отличный (\(rssi) дБм)"
        case (-70)...: "сигнал хороший (\(rssi) дБм)"
        case (-85)...: "сигнал слабый (\(rssi) дБм)"
        default: "на грани слышимости (\(rssi) дБм)"
        }
    }
}

#Preview {
    ContentView()
}

