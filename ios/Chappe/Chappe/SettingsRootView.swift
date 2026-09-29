import SwiftUI

// ============================================================================
// Вкладка «Настройки» (таббар v1, UI-бриф v0.4). Полные разделы брифа
// (Роуминг, LoRa, Безопасность, Приватность, Мед-данные, Локальная LLM)
// приедут своими задачами; сейчас здесь живут существующие служебные
// экраны, потерявшие собственные вкладки: SOS-конвейер, радиоузел, Dev.
// Ничего не удалено — всё доступно отсюда.
// ============================================================================

struct SettingsRootView: View {
    /// dev: --open-helper открывает экран «Помощник» без рук
    /// (скрин-прогоны в симуляторе; в Release всегда false)
    #if DEBUG
    @State private var showHelper = ProcessInfo.processInfo.arguments
        .contains("--open-helper")
    #else
    @State private var showHelper = false
    #endif

    @ObservedObject private var relay = RelayTransport.shared

    /// Язык развёртки смысловых кодов — выбор ПОЛУЧАТЕЛЯ (поручение
    /// 06.08: из Dev в обычные настройки). Отправка не меняется
    /// никогда — коды одни, язык выбирает читающий.
    @State private var unfoldLanguage = RMCodec.unfoldLanguage
    /// Предлагать ли короткий вариант сообщения (по умолчанию — да).
    @State private var offerShortening = TextOptimizer.isEnabled

    // Режим транспортов (10.08): один переключатель + галочки
    @State private var showResetConfirm = false
    @State private var didReset = false
    /// Б1 (13.08): уведомления запрещены системой — видно в приложении.
    @State private var notificationsDenied = false
    /// Профиль (мега-1, 14.08): черновик своего имени.
    @State private var profileName =
        Identity.hasCustomName ? Identity.displayName : ""
    @State private var manualMode = TransportMode.isManual
    @State private var wifiOn = TransportMode.manualMask.contains("wifi")
    @State private var bleOn = TransportMode.manualMask.contains("ble")
    @State private var loraOn = TransportMode.manualMask.contains("lora")

    /// Строка галочки транспорта: название по смыслу + подпись, какое
    /// железо за ним стоит (поправка владельца 10.08).
    private func transportRow(_ title: String, _ caption: String,
                              icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(RMDesign.textSecondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    /// Применить режим к тракту: маска — в настройку, интернет-релей и
    /// вид линка — по разрешениям (LoRa без галочки гасит mesh-линк).
    private func applyTransportMode() {
        TransportMode.isManual = manualMode
        var mask: Set<String> = []
        if wifiOn { mask.insert("wifi") }
        if bleOn { mask.insert("ble") }
        if loraOn { mask.insert("lora") }
        TransportMode.manualMask = mask
        // relay.enabled теперь производное от TransportMode (поле 29.09) —
        // отдельного присваивания нет и быть не может
        // Галка «Рядом» глушит BLE-эфир НЕМЕДЛЕННО (поле 13.08,
        // build 19): раньше маска резала только насос отправки, а
        // приём/реклама/ack жили — тумблер «не работал» на ощупь
        NearbyTransport.shared.setActive(TransportMode.bleAllowed)
        // след в дневник (полевой разбор 13.08 шёл вслепую: по логу
        // нельзя было сказать, какие галочки стояли в момент отправки)
        TransportDiary.note("[настройки] режим: "
            + (manualMode ? "ручной, пути [\(mask.sorted().joined(separator: ","))]"
                          : "авто"))
        let delivery = DeliveryManager.shared
        if !TransportMode.loraAllowed, delivery.transportKind == "mesh" {
            delivery.transportKind = "demo"   // радио выключено галочкой
        } else if TransportMode.loraAllowed, manualMode, loraOn,
                  delivery.transportKind != "mesh" {
            delivery.transportKind = "mesh"   // форс LoRa включает линк
        }
    }

    /// Честная строка «каким путём уйдёт сообщение прямо сейчас».
    private var pathNow: String {
        if !relay.enabled {
            return DeliveryManager.shared.radioReady
                ? "радио" : "радиоустройство не подключено"
        }
        switch relay.pathKind {
        case .wifi: return "Wi-Fi"
        case .cellular: return "сотовая сеть"
        case .other: return "интернет"
        case .none:
            return DeliveryManager.shared.radioReady
                ? "радио (интернета нет)" : "связи нет"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Профиль (мега-1, 14.08): своё имя редактируется здесь
                // и тапом на «Моём QR»; дефолта «Chappe» больше нет
                Section {
                    TextField(Identity.unnamedPlaceholder,
                              text: $profileName)
                        .onSubmit {
                            Identity.displayName = profileName
                            profileName = Identity.displayName
                        }
                } header: {
                    Text("Ваше имя")
                } footer: {
                    Text("Имя увидят собеседники при знакомстве; "
                       + "код-ID под ним не меняется.")
                }
                .listRowBackground(RMDesign.surface1)

                // Связь — первым: это то, ради чего мессенджер (05.08).
                // Интернет — путь по умолчанию; радио — дополнительная
                // возможность для тех, у кого есть узел.
                // UX-проход 06.08: вместо ручного тумблера «доставка
                // через интернет» — режим. Автомат сам берёт самый
                // быстрый доступный путь (Wi-Fi → сотовая → радио);
                // «только радио» оставляет интернет для обновлений и
                // файлов помощника, но сообщения туда не пускает.
                Section {
                    // Один переключатель вместо двух входов в двух местах
                    // (постановка владельца 10.08 после стендового
                    // прогона: «перевёл в автомат и выключил через
                    // радио» — путало)
                    Picker(selection: $manualMode) {
                        Text("Автоматически").tag(false)
                        Text("Ручной выбор").tag(true)
                    } label: {
                        Label("Как отправлять", systemImage: "arrow.triangle.branch")
                    }
                    .onChange(of: manualMode) { applyTransportMode() }
                    // Галочки — по СМЫСЛУ, не по железу (поправка
                    // владельца 10.08: «Wi-Fi» путал — прямой Wi-Fi
                    // между телефонами живёт в «Рядом», не в интернете)
                    if manualMode {
                        Toggle(isOn: $wifiOn) {
                            transportRow("Интернет", "Wi-Fi или сотовая",
                                         icon: "globe")
                        }
                        .onChange(of: wifiOn) { applyTransportMode() }
                        // подпись честная СЕЙЧАС (поручение 10.08):
                        // Wi-Fi Aware не поднимается (паринг отключён
                        // из-за системного краша 09.08) — «Wi-Fi
                        // напрямую» вернётся в подпись, когда канал
                        // реально заработает; врущий ярлык запрещён
                        Toggle(isOn: $bleOn) {
                            transportRow("Рядом", "Bluetooth",
                                         icon: "dot.radiowaves.left.and.right")
                        }
                        .onChange(of: bleOn) { applyTransportMode() }
                        Toggle(isOn: $loraOn) {
                            transportRow("Радио (LoRa)",
                                         "через радиоустройство",
                                         icon: "antenna.radiowaves.left.and.right")
                        }
                        .onChange(of: loraOn) { applyTransportMode() }
                        // Пустая маска — законное состояние, но молчать
                        // о нём нельзя (полевой прогон 13.08: сняли все
                        // галочки, ожидая «чистый Wi-Fi», и сообщения
                        // честно легли в очередь навсегда)
                        if !wifiOn && !bleOn && !loraOn {
                            Label("Ни один путь не отмечен — сообщения "
                                + "не будут отправляться",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(RMDesign.warning)
                        }
                    }
                    LabeledContent("Сейчас", value: pathNow)
                    // Б1 (13.08): запрет уведомлений системой был
                    // невидим — «не приходят» выяснялось полевым
                    // разбором. Строка появляется только при запрете.
                    if notificationsDenied {
                        Button {
                            if let url = URL(
                                string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Уведомления запрещены системой — "
                                + "включить в Настройках iOS",
                                  systemImage: "bell.slash")
                                .font(.footnote)
                                .foregroundStyle(RMDesign.warning)
                        }
                    }
                    NavigationLink {
                        BLECheckView()
                    } label: {
                        Label("Радиоустройства (LoRa)",
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Связь")
                } footer: {
                    // подпись — из TransportMode (мега-10): авто = все
                    // пути, галки живут только в ручном
                    Text(TransportMode.footerText(manual: manualMode))
                }
                .listRowBackground(RMDesign.surface1)

                // Оптимизатор (часть 2 брифа 08.08). Формулировка про то,
                // что человек получает, а не про механизм: слова «модель»,
                // «словарь», «пакеты» тут ни при чём.
                Section {
                    Toggle(isOn: $offerShortening) {
                        Label("Предлагать сокращать сообщения",
                              systemImage: "scissors")
                    }
                    .onChange(of: offerShortening) {
                        TextOptimizer.isEnabled = offerShortening
                    }
                } header: {
                    Text("Сообщения")
                } footer: {
                    Text("Для отправки без интернета: короче — значит "
                       + "быстрее. Приложение предложит вариант покороче, "
                       + "а вы решите, отправлять его или свой.")
                }
                .listRowBackground(RMDesign.surface1)

                Section {
                    Picker(selection: $unfoldLanguage) {
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                    } label: {
                        Label("Язык сообщений", systemImage: "character.book.closed")
                    }
                    .onChange(of: unfoldLanguage) {
                        RMCodec.unfoldLanguage = unfoldLanguage
                    }
                } header: {
                    Text("Язык")
                } footer: {
                    Text("На каком языке разворачивать смысловые "
                       + "сообщения. Влияет только на показ у вас — "
                       + "собеседник выбирает свой язык сам.")
                }
                .listRowBackground(RMDesign.surface1)

                Section {
                    NavigationLink {
                        ModelInstallView()
                    } label: {
                        Label("Помощник (локальная модель)",
                              systemImage: "sparkle")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("О приложении", systemImage: "info.circle")
                    }
                }
                .listRowBackground(RMDesign.surface1)

                // Начать заново — виден и в TestFlight/App Store: снос
                // приложения личность НЕ сбрасывает (Keychain переживает
                // деинсталляцию), поэтому прошлый чат воскресает после
                // переустановки; настоящий чистый лист — только отсюда.
                Section {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Начать заново", systemImage: "trash")
                            .foregroundStyle(RMDesign.danger)
                    }
                } header: {
                    Text("Сброс")
                } footer: {
                    Text("Сотрёт вашу личность и все чаты и создаст новую "
                       + "личность. Прошлые сообщения станут недоступны, "
                       + "собеседникам придётся добавить вас заново. "
                       + "Переустановка приложения этого НЕ делает.")
                }
                .listRowBackground(RMDesign.surface1)

                // ВРЕМЕННО и в TestFlight (полевой прогон 13.08):
                // парный зонд знакомства телефонов — владелец гоняет
                // его на двух телефонах из магазинной сборки. Убрать
                // вместе с включением прод-паринга.
                if #available(iOS 26.0, *) {
                    Section("Диагностика (временно)") {
                        NavigationLink {
                            AwarePairProbeView()
                        } label: {
                            Label("Зонд знакомства телефонов (Wi-Fi)",
                                  systemImage: "wifi")
                        }
                    }
                    .listRowBackground(RMDesign.surface1)
                }

                // Служебные экраны — только DEBUG-сборка (подача 06.08):
                // в TestFlight/App Store их нет вовсе
                #if DEBUG
                Section("Служебные экраны") {
                    NavigationLink {
                        SOSExtractView()
                    } label: {
                        Label("SOS-конвейер (dev)", systemImage: "cross.case")
                    }
                    NavigationLink {
                        DevSettingsView()
                    } label: {
                        Label("Dev", systemImage: "wrench.and.screwdriver")
                    }
                }
                .listRowBackground(RMDesign.surface1)
                #endif
            }
            .scrollContentBackground(.hidden)
            .rmScreenBackground()
            .navigationTitle("Настройки")
            // статус разрешения уведомлений — на каждый вход на экран
            .task { notificationsDenied = await IncomingNotifier
                .authorizationDenied() }
            .navigationDestination(isPresented: $showHelper) {
                ModelInstallView()
            }
            .confirmationDialog("Начать заново?",
                                isPresented: $showResetConfirm,
                                titleVisibility: .visible) {
                Button("Стереть всё и создать новую личность",
                       role: .destructive) {
                    AppReset.freshStart()
                    didReset = true
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Необратимо. Все чаты и ваша личность будут стёрты.")
            }
            .alert("Готово — начато заново", isPresented: $didReset) {
                Button("OK") {}
            } message: {
                Text("Закройте приложение полностью (смахните из "
                   + "переключателя) и откройте снова — оно поднимется с "
                   + "новой личностью и пустыми чатами.")
            }
        }
    }
}
