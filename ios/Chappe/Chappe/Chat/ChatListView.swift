import SwiftUI
import Combine
import PhotosUI

// ============================================================================
// Список чатов (веха, фаза 2): демо-собеседник остаётся с пометкой
// «демо», новые чаты — по контактам. Обмен: «мой QR» + сканер;
// подтверждение добавления с отпечатком.
// ============================================================================

/// Подозрение на подмену ключа (WP1): ждёт явного решения человека.
struct KeyChangePrompt: Identifiable {
    let existing: Contact
    let candidate: Contact
    var id: String { candidate.id }
}

@MainActor
final class ChatListModel: ObservableObject {
    @Published var contacts: [Contact] = []
    /// Непрочитанные по контакту (счётчик в списке чатов).
    @Published var unread: [String: Int] = [:]
    @Published var candidate: Contact?      // ждёт подтверждения человеком
    @Published var keyChange: KeyChangePrompt?
    /// Причина отказа предложить карточку (для подсказки скана): своя
    /// карточка отличается от «не похоже на контакт».
    @Published var proposeRejection: String?

    /// Своя карточка? Ключ отсканированного == мой — контакт не создаём,
    /// эхо-чата с собой нет (решение владельца 12.08).
    private func isSelfCard(_ contact: Contact) -> Bool {
        contact.id == Identity.myFingerprint()
    }

    func reload() {
        // Сортировка по времени последнего сообщения и счётчики
        // непрочитанных (замечание владельца 02.08): свежий чат сверху.
        let all = ContactStore.load()
        unread = Dictionary(uniqueKeysWithValues: all.map {
            ($0.id, HumanChatStore.unreadCount(contactID: $0.id))
        })
        let activity = Dictionary(uniqueKeysWithValues: all.map {
            ($0.id, HumanChatStore.lastActivity(contactID: $0.id)
                ?? Date(timeIntervalSince1970: 0))
        })
        contacts = all.sorted {
            (activity[$0.id] ?? .distantPast) > (activity[$1.id] ?? .distantPast)
        }
    }

    func propose(payload: String) -> Bool {
        guard let contact = ContactStore.parse(payload) else {
            proposeRejection = nil       // не карточка вовсе
            return false
        }
        if isSelfCard(contact) {
            proposeRejection = "Это ваша карточка — контакт не создаётся"
            return false
        }
        proposeRejection = nil
        candidate = contact
        return true
    }

    /// Кандидат из галереи — уже разобран и помечен непроверенным.
    @discardableResult
    func propose(contact: Contact) -> Bool {
        if isSelfCard(contact) {
            proposeRejection = "Это ваша карточка — контакт не создаётся"
            return false
        }
        proposeRejection = nil
        candidate = contact
        return true
    }

    func confirmCandidate() {
        guard let candidate else { return }
        self.candidate = nil
        // Гейт смены ключа (WP1): то же имя с другим ключом не
        // принимается молча — наружу громкое предупреждение
        switch ContactStore.upsertGuarded(candidate) {
        case .saved:
            reload()
        case .keyChangeSuspected(let existing, let fresh):
            keyChange = KeyChangePrompt(existing: existing, candidate: fresh)
        }
    }

    /// Явное принятие нового ключа после предупреждения: старый контакт
    /// уходит, история переезжает, доверие сброшено до пересверки.
    func acceptKeyChange(_ prompt: KeyChangePrompt) {
        ContactStore.acceptKeyChange(oldID: prompt.existing.id,
                                     prompt.candidate)
        keyChange = nil
        reload()
    }

    func remove(_ id: String) {
        if let contact = ContactStore.load().first(where: { $0.id == id }) {
            ContactPurge.purge(contact)   // полное стирание, не частичное
        } else {
            ContactStore.remove(id: id)
        }
        reload()
    }

    // MARK: B2 — блок и удаление с надгробием

    /// Блок без удаления: чат остаётся, входящие этого ключа гаснут.
    func block(_ contact: Contact) {
        ContactAdmission.block(id: contact.id)
        reload()
    }

    /// Удаление: надгробие (имя → последний ключ) — возврат с другим
    /// ключом поднимет тревогу; блок опционально; лента и рэтчет — в ноль.
    func delete(_ contact: Contact, andBlock: Bool) {
        ContactAdmission.leaveTombstone(name: contact.name, id: contact.id,
                                        blocked: andBlock)
        if andBlock { ContactAdmission.block(id: contact.id) }
        ContactPurge.purge(contact)   // полное стирание = чистый лист
        reload()
    }
}

struct ChatListView: View {
    /// Демо-чат жив только для UI-тестов (замок клавиатуры): дверь по
    /// launch-аргументу --demo-chat, в TestFlight/AppStore выключено.
    static var demoChatEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--demo-chat")
        #else
        return false
        #endif
    }

    @StateObject private var model = ChatListModel()
    @State private var showScanner = false
    @State private var scanHint: String?
    /// Знакомство телефонов после знакомства людей (фаза 1 «рядом»).
    @State private var showPairingPicker = false
    @State private var openedContact: Contact?
    // Импорт из галереи (30.07): системный пикер без разрешений,
    // Vision локально; несколько QR → выбор человеком
    @State private var galleryItem: PhotosPickerItem?
    @State private var galleryChoices: [Contact] = []
    @State private var verifyTarget: Contact?
    /// B2: контакт под шитом «Заблокировать / Удалить / Удалить и
    /// заблокировать» (свайп → крестик).
    @State private var manageTarget: Contact?
    @State private var showMyQR = false

    var body: some View {
        NavigationStack {
            List {
                // Первый запуск (подача 06.08): человек без контактов
                // видит не пустой список, а что это за приложение и
                // ровно одно следующее действие. Первое впечатление —
                // главный риск удаления.
                if model.contacts.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Сообщения без интернета и сотовой связи")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(RMDesign.textPrimary)
                            // словарь UI: ни «LoRa», ни «mesh» — только
                            // «радио» и «узел» (docs/ui_vocabulary.md)
                            Text("Chappe шлёт сообщения через интернет, "
                               + "когда он есть, и по радио, когда его "
                               + "нет. Переписка видна только вам и "
                               + "собеседнику.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(RMDesign.textSecondary)
                            Text("Чтобы начать, добавьте собеседника: "
                               + "покажите ему свой код или отсканируйте "
                               + "его — кнопка «+» справа сверху.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(RMDesign.textSecondary)
                            HStack(spacing: 10) {
                                Button {
                                    showMyQR = true
                                } label: {
                                    Label("Мой код", systemImage: "qrcode")
                                        .font(.system(size: 14.5, weight: .medium))
                                        .foregroundStyle(RMDesign.accentLight)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 44)
                                        .background(RMDesign.accentSurface)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                Button {
                                    showScanner = true
                                } label: {
                                    Label("Сканировать",
                                          systemImage: "qrcode.viewfinder")
                                        .font(.system(size: 14.5, weight: .medium))
                                        .foregroundStyle(RMDesign.accentLight)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 44)
                                        .background(RMDesign.accentSurface)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(RMDesign.surface1)
                }
                // Софи здесь НЕТ (задание 30.07): у неё своя вкладка.
                // Чаты с людьми и чаты с Софи не смешиваются в одном
                // списке — у людей пузыри несут статусы доставки, у Софи
                // их нет, смешение создало бы ложное впечатление, что
                // вопрос Софи улетел в эфир (тест ChatSeparationTests).
                // Демо-чата «Как это выглядит» здесь больше НЕТ (полевой
                // пакет 13.08): живые чаты появились, песочница смущала.
                // Хранилище chat_demo.json остаётся служебной раковиной
                // (SOS/BEACON при неоднозначном отправителе) — UI-входа
                // к ней нет намеренно. Исключение — UI-тесты: замку
                // клавиатуры нужен чат без контактов, дверь по
                // launch-аргументу и только в DEBUG.
                Section {
                    if Self.demoChatEnabled {
                        NavigationLink {
                            HumanChatView()
                        } label: {
                            Label("Как это выглядит",
                                  systemImage: "person.crop.circle.dashed")
                                .foregroundStyle(RMDesign.textPrimary)
                        }
                        .listRowBackground(RMDesign.surface1)
                    }
                    ForEach(model.contacts) { contact in
                        NavigationLink {
                            HumanChatView(contact: contact)
                        } label: {
                            HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(contact.name)
                                            .foregroundStyle(RMDesign.textPrimary)
                                        // WP1: состояние сверки видно
                                        // всегда — три честных состояния
                                        trustBadge(contact)
                                    }
                                    Text(contact.id)
                                        .font(.system(size: 11,
                                                      design: .monospaced))
                                        .foregroundStyle(RMDesign.textTertiary)
                                }
                            } icon: {
                                Image(systemName: contact.isUnverified
                                      ? "person.crop.circle.badge.questionmark"
                                      : "person.crop.circle")
                                    .foregroundStyle(contact.isUnverified
                                        ? RMDesign.warning
                                        : RMDesign.accentLight)
                            }
                            Spacer(minLength: 8)
                            // счётчик непрочитанных (замечание 02.08)
                            if let count = model.unread[contact.id],
                               count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(RMDesign.accent)
                                    .clipShape(Capsule())
                            }
                            }
                        }
                        .listRowBackground(RMDesign.surface1)
                        .contextMenu {
                            // сверка доступна всегда, не только для
                            // «непроверен»: пересверка — нормальное дело
                            Button("Сверить ключ…",
                                   systemImage: "checkmark.seal") {
                                verifyTarget = contact
                            }
                        }
                        // B2: свайп → крестик → шит с тремя исходами
                        // (немедленного удаления больше нет)
                        .swipeActions(edge: .trailing,
                                      allowsFullSwipe: false) {
                            Button {
                                manageTarget = contact
                            } label: {
                                Label("Управлять", systemImage: "xmark")
                            }
                            .tint(RMDesign.danger)
                        }
                    }
                } header: {
                    Text("Чаты")
                        .foregroundStyle(RMDesign.textSecondary)
                } footer: {
                    if let scanHint {
                        Text(scanHint).foregroundStyle(RMDesign.warning)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(RMDesign.background)
            .navigationTitle("Чаты")
            .toolbar {
                // Ф5.1 (бриф 31.07): одна «+» вместо трёх иконок;
                // галерея и фонарь переехали внутрь экрана камеры
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Показать мой код", systemImage: "qrcode") {
                            showMyQR = true
                        }
                        Button("Сканировать код",
                               systemImage: "qrcode.viewfinder") {
                            showScanner = true
                        }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(RMDesign.accentLight)
                    }
                    .accessibilityLabel("Добавить контакт")
                }
            }
            .navigationDestination(isPresented: $showMyQR) { MyQRView() }
            .onChange(of: galleryItem) {
                guard let item = galleryItem else { return }
                galleryItem = nil
                Task { await importFromGallery(item) }
            }
            .confirmationDialog(
                "На изображении несколько карточек — какую добавить?",
                isPresented: .init(get: { !galleryChoices.isEmpty },
                                   set: { if !$0 { galleryChoices = [] } }),
                titleVisibility: .visible) {
                ForEach(galleryChoices) { contact in
                    Button("\(contact.name) · \(contact.id)") {
                        galleryChoices = []
                        if !model.propose(contact: contact) {
                            scanHint = model.proposeRejection
                        }
                    }
                }
                Button("Отмена", role: .cancel) { galleryChoices = [] }
            }
            .sheet(item: $verifyTarget) { contact in
                ContactVerifySheet(contact: contact) {
                    // «проверен» — только после сверки, явным действием
                    ContactStore.markVerified(id: contact.id)
                    verifyTarget = nil
                    model.reload()
                } onCancel: {
                    verifyTarget = nil
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $showScanner) {
                // Ф5.1: внутри камеры — «из галереи» и «фонарь»
                ScannerSheet(onFound: { payload in
                    showScanner = false
                    if !model.propose(payload: payload) {
                        // своя карточка → точная подсказка, иначе «не похоже»
                        scanHint = model.proposeRejection
                            ?? "QR не похож на контакт \(AppIdentity.appName)"
                    }
                }, onGalleryItem: { item in
                    showScanner = false
                    Task { await importFromGallery(item) }
                })
                .ignoresSafeArea()
            }
            .sheet(item: $model.candidate) { candidate in
                ContactConfirmSheet(contact: candidate,
                                    onConfirm: {
                                        model.confirmCandidate()
                                        armPairingAfterAcquaintance()
                                    },
                                    onCancel: { model.candidate = nil })
                    // лист по содержимому: при .medium карточка висела
                    // внизу с пустотой сверху (полевой снимок 08.08)
                    .presentationDetents([.height(300), .medium])
            }
            // знакомство телефонов — сразу за знакомством людей, в том же
            // движении (фаза 1 «рядом», 07.08); повторно не появится
            .sheet(isPresented: $showPairingPicker) {
                if #available(iOS 26.0, *) {
                    VStack(spacing: 0) {
                        NearbyPairingCaption()
                        NearbyPairingPicker { showPairingPicker = false }
                    }
                    .background(RMDesign.background)
                }
            }
            .sheet(item: $model.keyChange) { prompt in
                // WP1: смена ключа — громкое предупреждение, не молча
                KeyChangeWarningSheet(
                    prompt: prompt,
                    onAccept: { model.acceptKeyChange(prompt) },
                    onReject: { model.keyChange = nil })
                    .presentationDetents([.medium, .large])
                    .interactiveDismissDisabled()
            }
            .navigationDestination(item: $openedContact) { contact in
                HumanChatView(contact: contact)
            }
            // B2: три исхода; блок помнит ключ, удаление оставляет
            // надгробие (возврат с другим ключом поднимет тревогу)
            .confirmationDialog(
                manageTarget.map { "«\($0.name)»" } ?? "",
                isPresented: Binding(get: { manageTarget != nil },
                                     set: { if !$0 { manageTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Заблокировать") {
                    if let c = manageTarget { model.block(c) }
                    manageTarget = nil
                }
                Button("Удалить", role: .destructive) {
                    if let c = manageTarget { model.delete(c, andBlock: false) }
                    manageTarget = nil
                }
                Button("Удалить и заблокировать", role: .destructive) {
                    if let c = manageTarget { model.delete(c, andBlock: true) }
                    manageTarget = nil
                }
                Button("Отмена", role: .cancel) { manageTarget = nil }
            } message: {
                Text("Блокировка помнит ключ: сообщения этого ключа "
                   + "перестанут приходить. Удаление стирает чат; если "
                   + "это имя вернётся с другим ключом — приложение "
                   + "поднимет тревогу о смене ключа.")
            }
            // приём тикает eventCounter — счётчики и порядок чатов
            // живут, пока список на экране (блок 6, 10.08: раньше
            // обновление было только при заходе на вкладку)
            .onReceive(DeliveryManager.shared.$eventCounter) { _ in
                model.reload()
            }
            .onAppear {
                model.reload()
                #if DEBUG
                // dev: --open-contact <id> открывает чат контакта
                // (скрины прогона вехи в симуляторе)
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "--open-contact"),
                   args.indices.contains(index + 1),
                   openedContact == nil {
                    openedContact = model.contacts
                        .first { $0.id == args[index + 1] }
                }
                #endif
            }
            .preferredColorScheme(.dark)
        }
    }

    /// Бейдж доверия (WP1): три состояния видны всегда — «проверен»
    /// (сверка была), «непроверен» (канал непроверенный, тревога),
    /// «не сверен» (нейтрально: сверки ещё не было).
    @ViewBuilder
    private func trustBadge(_ contact: Contact) -> some View {
        let (text, tint): (String, Color) = switch contact.verified {
        case .some(true): ("проверен", RMDesign.accentLight)
        case .some(false): ("непроверен", RMDesign.warning)
        case nil: ("не сверен", RMDesign.textTertiary)
        }
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16))
            .clipShape(Capsule())
            .foregroundStyle(tint)
    }

    /// Импорт из галереи: данные → Vision → маршрутизация исходов.
    /// Ошибки честные (в footer списка), не тишина. Несколько карточек —
    /// выбор человеком, первую молча не берём.
    /// Сразу после добавления контакта: знакомим и телефоны, пока люди
    /// рядом. Молча ничего не делаем, если телефон этого не умеет, они
    /// уже знакомы или карточка пришла непроверенным каналом (там сперва
    /// сверка отпечатка, а не связь).
    private func armPairingAfterAcquaintance() {
        // Выключатель после падения 08.08: системный экран знакомства
        // телефонов ронял приложение прямо на «Добавить» — то есть ломал
        // добавление контакта. Здесь этой проверки вчера не было, и
        // падение пришло с поля вторым заходом.
        guard #available(iOS 26.0, *), NearbyPairing.uiEnabled else { return }
        Task { @MainActor in
            guard await !NearbyPairing.alreadyPaired(),
                  NearbyPairing.isSupported else { return }
            showPairingPicker = true
        }
    }

    private func importFromGallery(_ item: PhotosPickerItem) async {
        scanHint = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            scanHint = "Не удалось открыть изображение"
            return
        }
        let outcome = GalleryQRDecoder.decode(image: image)
        switch outcome {
        case .contacts(let contacts) where contacts.count == 1:
            model.propose(contact: contacts[0])
        case .contacts(let contacts):
            galleryChoices = contacts
        case .noQR, .foreignQR:
            scanHint = GalleryQRDecoder.errorText(for: outcome)
        }
    }
}
