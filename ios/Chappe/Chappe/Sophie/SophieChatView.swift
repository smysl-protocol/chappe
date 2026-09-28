//
//  SophieChatView.swift
//  R+M — чат с Софи (sophie_presence, фаза 1: один чат).
//
//  Ответы идут через ModelScheduler как P2 (интерактив Софи), стриминг
//  токенов в пузырь, кнопка «стоп». Гейт приватности: чат доступен
//  только при локальном провайдере (sophie_presence §3).
//

import SwiftUI
import Combine

@MainActor
final class SophieChatModel: ObservableObject {

    @Published var messages: [SophieMessage]
    @Published var input = ""
    @Published var isGenerating = false
    @Published var gateOpen = ModelScheduler.isLocalProviderActive()
    @Published var errorMessage: String?

    /// nil — свободный чат; иначе предустановленный чат с базой знаний.
    let preset: SophiePreset?
    /// Свой чат из папки (sophie_presence §2); nil — пресет или legacy.
    let chat: SophieChatInfo?
    private let storageKey: String
    private lazy var knowledgeBase: KnowledgeBase? =
        preset.flatMap { try? KnowledgeBase.load(file: $0.kbFile) }
    /// Свободный чат смотрит во все базы приложения (маршрутизация SophieKnowledge).
    private lazy var allBases: [KnowledgeBase] =
        SophiePreset.allCases.compactMap { try? KnowledgeBase.load(file: $0.kbFile) }

    private var runTask: Task<Void, Never>?

    /// Планировщик как зависимость — тесты подменяют на мок.
    var scheduler: ModelScheduler = .shared

    /// Память Софи (шаг 3): в бою открывается с ключом из Keychain,
    /// тесты подменяют на temp-стор. nil — Keychain отказал (ход идёт
    /// без памяти, не падает).
    lazy var memory: SophieMemoryStore? = SophieMemoryStore.open()

    // Диктовка (on-device ru, ноль байт наружу). State-машина: во время
    // записи текст НЕ показывается (индикатор волна+таймер), по ■ буфер
    // ложится в поле как обычный вопрос Софи — семантического кодирования
    // нет, оно только для эфира.
    let dictation = SpeechDictation()
    @Published var isDictating = false
    @Published var dictationHint: String?
    private var inputBeforeRecording = ""
    private var dictationSync: AnyCancellable?

    func micTapped() {
        guard !isDictating else { return }
        // Короткое замыкание — только при отказе разрешений (дверь в
        // Настройки). При «on-device недоступен» тап ОБЯЗАН дойти до
        // start(): разрешения запрашиваются даже без поддержки, иначе
        // строка в Настройках не родится (полевой тупик тел 2, 10.08)
        if dictation.permissionDenied, let hint = dictation.unavailableHint {
            dictationHint = hint
            return
        }
        // Ф2.4: список голосовых команд — один раз, при первой диктовке
        dictationHint = Punctuator.commandsHintOnce()
        dictationDidStart()
        Task {
            if await !dictation.start() {
                isDictating = false
                dictationHint = dictation.unavailableHint
            }
        }
    }

    /// Снимок состояния до записи (тестируется отдельно от AVAudio).
    func dictationDidStart() {
        inputBeforeRecording = input
        isDictating = true
    }

    /// × — буфер в мусор, поле как было.
    func cancelDictation() {
        dictation.cancel()
        isDictating = false
    }

    /// ■ — распознанный текст в поле по стопу (отправляет человек).
    func dictationDidFinish(_ text: String) {
        guard isDictating else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let failure = dictation.recognitionFailure {
            dictationHint = failure
        }
        input = inputBeforeRecording.isEmpty || trimmed.isEmpty
            ? (inputBeforeRecording + trimmed)
            : inputBeforeRecording + " " + trimmed
        isDictating = false
    }

    init(preset: SophiePreset? = nil, chat: SophieChatInfo? = nil) {
        self.preset = preset
        self.chat = chat
        self.storageKey = preset.map { "chat_\($0.rawValue)" }
            ?? chat?.id ?? "chat"
        self.messages = SophieChatStore.load(key: storageKey)
        dictation.onFinished = { [weak self] text in
            self?.dictationDidFinish(text)
        }
        // волна/таймер/фаза «распознаю…» живут в SpeechDictation
        dictationSync = dictation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func refreshGate() {
        gateOpen = ModelScheduler.isLocalProviderActive()
    }

    /// Пресеты не удаляются, но историю можно очистить (sophie_presence §2.1).
    /// Суммарий и курсор свёртки очищаются вместе с историей.
    func clearHistory() {
        messages = []
        SophieChatStore.save(messages, key: storageKey)
        SophieChatStore.deleteSummary(key: storageKey)
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Явная команда SOS (3.6): из любого чата Софи открывает
        // карточку-черновик. В историю и модель текст не уходит.
        // Работает и без локальной модели: карточка заполняется руками.
        if SOSCommand.isCommand(text) {
            input = ""
            sosContext = ""
            showSOSDraft = true
            Task { await SophieTrace.shared.note(.intercept(kind: .sos)) }
            return
        }
        // WP3 (02.08): вопросы о состоянии сети/узлов/доставки модель
        // НЕ видит вообще — код собирает карточку статуса (реальный
        // случай: модель отвечала «я проверила — узлов нет», ничего не
        // проверяя; непреложное №9 — гейт кодом, не промптом).
        // Работает и без локальной модели: фактам LLM не нужна.
        if NetworkStatus.isNetworkQuestion(text) {
            input = ""
            messages.append(SophieMessage(role: .user, text: text))
            var card = SophieMessage(
                role: .sophie,
                text: NetworkStatus.cardText(NetworkStatus.liveSource()))
            card.statusCard = true
            messages.append(card)
            // при необходимости — курированный текст из пака «Связь»
            // (статический контент базы, не генерация)
            if let kb = commsKBSupplement(for: text) {
                messages.append(SophieMessage(role: .sophie, text: kb))
            }
            SophieChatStore.save(messages, key: storageKey)
            Task { await SophieTrace.shared.note(.intercept(kind: .network)) }
            return
        }
        guard !isGenerating, gateOpen else { return }
        input = ""
        runTask = Task { await run(text) }
    }

    /// Дополнение к карточке статуса: подходящая секция пака «Связь»
    /// как есть (курированный текст, не модель). nil — совпадений нет.
    private func commsKBSupplement(for text: String) -> String? {
        guard let comms = try? KnowledgeBase.load(file: SophiePreset.comms.kbFile)
        else { return nil }
        let sections = KnowledgeRetriever.select(from: comms, query: text)
            .filter { !$0.isCore && !$0.isTOC }
        guard let top = sections.first else { return nil }
        return "Из базы «Связь» — \(top.title):\n\(top.body)"
    }

    // Карточка SOS (Ф3): открывается командой «SOS» или кнопкой в
    // SOS-чате; отправка — только подтверждением человека внутри.
    @Published var showSOSDraft = false
    var sosContext = ""

    /// «Стоп»: генерация обрывается, уже напечатанное остаётся в пузыре.
    func stop() {
        Task { [scheduler] in await scheduler.cancelActive() }
    }

    /// «Продолжить» на остановленном пузыре: история + частичный ответ
    /// как префикс ассистента (тёплый KV — эти токены уже в кэше).
    /// Маркер «остановлено» снимается при успешном продолжении.
    func continueGeneration(_ id: UUID) {
        guard !isGenerating, gateOpen,
              let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .sophie, messages[index].isStopped
        else { return }
        runTask = Task { await continueRun(at: index) }
    }

    private func continueRun(at index: Int) async {
        isGenerating = true
        errorMessage = nil
        let replyID = messages[index].id
        let partial = messages[index].text

        defer {
            isGenerating = false
            SophieChatStore.save(messages, key: storageKey)
        }

        // Окно — история ДО частичного ответа; последняя реплика
        // пользователя уходит как «новое сообщение» (формат промпта тот же,
        // что и в обычном ответе, — общий префикс для тёплого KV)
        let summaryState = SophieChatStore.loadSummary(key: storageKey)
        let summary = summaryState.text.isEmpty ? nil : summaryState.text
        let before = Array(messages[min(summaryState.cursor, index)..<index])
        guard let lastUser = before.last, lastUser.role == .user else { return }
        let window = SophiePrompt.window(Array(before.dropLast()),
                                       budget: max(500, SophiePrompt.tokenBudget
                                           - (summary.map { SophiePrompt.estimatedTokens($0) } ?? 0)))
        let prompt = SophiePrompt.userPrompt(window: window,
                                           newText: lastUser.text,
                                           summary: summary,
                                           clockLine: SophieClock.nowLine())

        do {
            let system = try SophiePrompt.systemPrompt()
            let request = LLMRequest(prompt: prompt,
                                     systemPrompt: system,
                                     maxTokens: 400,
                                     assistantPrefix: partial)
            // Продолжение — тоже финальный вызов цикла (метрики в след)
            let response = try await SophieLoop(scheduler: scheduler)
                .finalAnswer(request) { chunk in
                    Task { @MainActor in
                        self.append(chunk: chunk, to: replyID)
                    }
                }
            // Продолжение уже дописано стримом в пузырь. Страховка на
            // случай, если стрим не донёс ни чанка: приклеить итог сами.
            if let i = messages.firstIndex(where: { $0.id == replyID }),
               messages[i].text == partial, !response.text.isEmpty {
                messages[i].text = partial
                    + (partial.isEmpty ? "" : " ") + response.text
            }
            // Пост-валидатор дат (Ф6) — по всему дописанному пузырю
            if let i = messages.firstIndex(where: { $0.id == replyID }) {
                let gated = SophieClock.validated(messages[i].text)
                SophieClock.logMismatches(gated.mismatches,
                                          context: "продолжение (\(storageKey))")
                messages[i].text = gated.text
            }
            clearStopped(replyID)   // успешное продолжение снимает маркер
        } catch {
            if case LLMError.cancelled = error {
                // остановили и продолжение — маркер остаётся, текст тоже
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func clearStopped(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].stopped = nil
    }

    private func run(_ text: String) async {
        isGenerating = true
        errorMessage = nil

        // Шаг 2 линии Софи: ход идёт через легибл-цикл (раунды
        // инструментов + финальный ответ) с JSONL-следом. Планировщик —
        // инъецируемый (тесты подменяют мок), в бою тот же .shared.
        let loop = SophieLoop(scheduler: scheduler)
        await loop.trace.note(.turnStart(chat: preset == nil ? .free : .preset))

        // Перехват ДО модели (Ф6): вопрос целиком о дате/времени/дне
        // недели отвечает код через DateFormatter — модель не
        // вызывается вообще. Это гарантия правильного ответа.
        if let direct = SophieClock.directAnswer(for: text) {
            messages.append(SophieMessage(role: .user, text: text))
            messages.append(SophieMessage(role: .sophie, text: direct))
            isGenerating = false
            SophieChatStore.save(messages, key: storageKey)
            await loop.trace.note(.intercept(kind: .clock))
            await loop.trace.note(.turnEnd(llmCalls: 0,
                                           replyChars: direct.count))
            return
        }

        // Поле 22.08 (скрин владельца): реплика и пузырь ответа — в
        // ленту МГНОВЕННО, до всякой работы модели; «пропавшее на
        // полминуты сообщение» читалось как потеря ввода. Окно промпта
        // строится по снапшоту истории ДО этой пары.
        let history = messages
        messages.append(SophieMessage(role: .user, text: text))
        let reply = SophieMessage(role: .sophie, text: "")
        messages.append(reply)
        let replyID = reply.id

        // Память (шаг 3, только свободный чат): гейт решает «нужна ли
        // ходу память» ДО поиска — эвристики кодом, неоднозначное
        // эскалируется в короткий вызов (цифры в gate_h/gate_m трейса)
        var memoryBlock: String?
        if preset == nil, let memory {
            let factsEmpty = await memory.facts().isEmpty
            let episodesEmpty = await memory.episodes().isEmpty
            let isEmpty = factsEmpty && episodesEmpty
            let gate = SophieRetrievalGate(scheduler: scheduler,
                                           trace: loop.trace)
            let decision = await gate.decide(for: text, memoryIsEmpty: isEmpty)
            if decision.retrieve {
                memoryBlock = SophieMemoryBlock.compose(
                    facts: await memory.searchFacts(decision.query),
                    episodes: await memory.searchEpisodes(decision.query))
            }
        }

        // Инструменты (фаза 2а, только свободный чат): раунды выбора
        // в цикле, выполнение кодом, результат уходит в финальный вызов.
        // Сбой выбора не роняет чат — падаем в обычный ответ.
        var toolBlock: String?
        var llmCalls = 0
        if preset == nil {
            let rounds = await loop.toolRoundsCounted(for: text)
            toolBlock = rounds.block
            llmCalls = rounds.llmCalls
        }

        // Окно строится по истории ДО нового сообщения. Для пресета
        // бюджет знаний (~1200) вычитается из окна истории (kb_spec §5).
        // Свёрнутая часть (до курсора суммария) в окно не попадает —
        // её факты уже в суммарии (sophie_presence §1).
        let knowledgeBlock: String? = {
            let base: String? = {
                if let toolBlock { return toolBlock }
                if let preset, let base = knowledgeBase {
                    return SophieKnowledge.blockForPreset(preset, query: text, base: base)
                }
                return SophieKnowledge.blockForFreeChat(query: text, bases: allBases)
            }()
            // Память — первой (стабильный префикс дня → теплее KV)
            let parts = [memoryBlock, base].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }()
        let summaryState = SophieChatStore.loadSummary(key: storageKey)
        let summary = summaryState.text.isEmpty ? nil : summaryState.text
        let historyBudget = SophiePrompt.tokenBudget
            - (knowledgeBlock.map { KnowledgeRetriever.estimatedTokens($0) } ?? 0)
            - (summary.map { SophiePrompt.estimatedTokens($0) } ?? 0)
        let unsummarized = summaryState.cursor < history.count
            ? Array(history[summaryState.cursor...]) : []
        let window = SophiePrompt.window(unsummarized,
                                       budget: max(500, historyBudget))
        // Данные устройства — на КАЖДОМ ходе, не при старте сессии (Ф6)
        let prompt = SophiePrompt.userPrompt(window: window, newText: text,
                                           knowledgeBlock: knowledgeBlock,
                                           summary: summary,
                                           clockLine: SophieClock.nowLine())

        defer {
            isGenerating = false
            SophieChatStore.save(messages, key: storageKey)
            // Фоновые P3 после каждого ответа: свёртка старого в суммарий
            // и консолидация в долговременную память (шаг 3.3); оба
            // вытесняются любым P0–P2 и продолжаются с своих курсоров
            let key = storageKey
            let memory = self.memory
            Task.detached(priority: .background) {
                await SophieSummarizer.shared.runIfNeeded(key: key)
                if let memory {
                    await SophieConsolidator.shared.runIfNeeded(
                        key: key, memory: memory)
                }
            }
        }

        do {
            let system = try SophiePrompt.systemPrompt()
            let request = LLMRequest(prompt: prompt,
                                     systemPrompt: system,
                                     maxTokens: 400)   // сэмплинг чата — из конфига

            // P2: интерактив Софи (sophie_presence §5), финальный вызов цикла
            let response = try await loop.finalAnswer(request) { chunk in
                Task { @MainActor in
                    self.append(chunk: chunk, to: replyID)
                }
            }
            // Финальный текст — от провайдера (обрезки/трим), стрим мог отстать
            // Пост-валидатор дат (Ф6): упомянутые день недели / «сегодня»-
            // дата / «сейчас»-время сверяются с системными; расхождение
            // подменяется, факт — в отладочный лог
            let gated = SophieClock.validated(response.text)
            SophieClock.logMismatches(gated.mismatches,
                                      context: "чат Софи (\(storageKey))")
            set(text: gated.text, for: replyID)
            await loop.trace.note(.turnEnd(llmCalls: llmCalls + 1,
                                           replyChars: gated.text.count))
        } catch {
            if case LLMError.cancelled = error {
                // Оборвали кнопкой: частичный ответ остаётся с маркером
                // «остановлено вами» (мокап sophie_stopped); пустой — убираем
                markStopped(replyID)
            } else {
                removeIfEmpty(replyID)
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Вызов №1 (P2): модель выбирает инструмент; код выполняет.
    /// nil — инструмент не нужен или выбор не удался (обычный ответ).
    /// Делегирует в SophieLoop (шаг 2) — точка входа сохранена для
    /// шёпота @Софи в HumanChatView (зона app-сессии, не трогаем).
    static func toolBlockIfNeeded(for text: String) async -> String? {
        await SophieLoop().toolRounds(for: text)
    }

    private func markStopped(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.remove(at: index)
        } else {
            messages[index].stopped = true
        }
    }

    private func append(chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += chunk
    }

    private func set(text: String, for id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func removeIfEmpty(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.remove(at: index)
        }
    }
}

struct SophieChatView: View {
    @StateObject private var model: SophieChatModel
    @EnvironmentObject private var router: TabRouter
    @State private var confirmClear = false

    init(preset: SophiePreset? = nil, chat: SophieChatInfo? = nil) {
        _model = StateObject(wrappedValue: SophieChatModel(preset: preset,
                                                         chat: chat))
    }

    var body: some View {
        Group {
            // SOS-чат живёт и БЕЗ модели (Ф1.4): карточка, отправка и
            // отбой от неё не зависят — гейт скрывал бы вход в SOS.
            // Композер при закрытом гейте честно отключён.
            if model.gateOpen || model.preset == .sos {
                chat
            } else {
                // Гейт приватности (sophie_presence §3) по мокапу
                // sophie_local_only_gate: тон — не ошибка, «защита работает»
                localOnlyGate
            }
        }
        .navigationTitle(model.preset?.title ?? model.chat?.title ?? "\(AppIdentity.assistantName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Пресеты не удаляются — но историю очистить можно
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.messages.isEmpty || model.isGenerating)
            }
        }
        .confirmationDialog("Очистить историю этого чата?",
                            isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { model.clearHistory() }
        }
        .sheet(isPresented: $model.showSOSDraft, onDismiss: {
            sosSession = SOSCenter.loadSession()
        }) {
            SOSDraftSheet(context: model.sosContext)
        }
        .confirmationDialog("Отправить отбой всем, кто получил сигнал?",
                            isPresented: $confirmStandDown,
                            titleVisibility: .visible) {
            // Необратимое действие — словами, не иконкой
            Button("Отправить отбой", role: .destructive) {
                try? SOSCenter.standDown()
                sosSession = SOSCenter.loadSession()
            }
        }
        .onAppear {
            model.refreshGate()
            sosSession = SOSCenter.loadSession()
        }
    }

    @State private var sosSession: SOSSession?
    @State private var confirmStandDown = false

    /// Шапка SOS-чата (3.1–3.4): честная карточка, статус сессии, кнопки.
    @ViewBuilder
    private var sosHeader: some View {
        VStack(spacing: 10) {
            SOSInfoCard(contactCount: ContactStore.load().count)

            if let session = sosSession {
                if session.isActive {
                    VStack(spacing: 6) {
                        Label("SOS отправлен \(ChatEntry.hhmm(session.sentAt))"
                              + " · контактам: \(session.recipientMsgIDs.count)",
                              systemImage: "light.beacon.max")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RMDesign.danger)
                        Text(session.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(RMDesign.textSecondary)
                        // Отбой обязателен (3.4)
                        Button {
                            confirmStandDown = true
                        } label: {
                            Text("Помощь больше не нужна — отбой")
                                .font(.system(size: 14, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(RMDesign.danger)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RMDesign.surface1,
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(RMDesign.danger.opacity(0.55)))
                } else if let downAt = session.standDownAt {
                    Label("Отбой отправлен \(ChatEntry.hhmm(downAt))",
                          systemImage: "checkmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(RMDesign.textSecondary)
                }
            }

            if sosSession?.isActive != true {
                Button {
                    model.sosContext = model.messages
                        .last(where: { $0.role == .user })?.text ?? ""
                    model.showSOSDraft = true
                } label: {
                    Label("Заполнить карточку SOS",
                          systemImage: "light.beacon.max")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(RMDesign.danger)
            }
        }
        .padding(.bottom, 6)
    }

    @FocusState private var inputFocused: Bool

    // Стилистика — по design/sophie/design_tokens.md (тёмная тема, синий Софи).
    // Композер в safeAreaInset: лента не прячется под него и под
    // клавиатуру, inset у ScrollView всегда корректный.
    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: SophieDesign.messageSpacing) {
                    // Чат SOS: постоянная честная карточка — кому уходит
                    // сигнал, как передаётся позиция, чего ждать (3.2)
                    if model.preset == .sos {
                        sosHeader
                            .padding(.top, 8)
                    }
                    if model.messages.isEmpty, model.preset != .sos {
                        Text("\(AppIdentity.assistantName) — локальный ассистент. Всё остаётся "
                           + "на устройстве.")
                            .font(SophieDesign.captionFont)
                            .foregroundStyle(SophieDesign.textTertiary)
                            .padding(.top, 24)
                    }
                    ForEach(model.messages) { message in
                        bubble(message,
                               isStreaming: model.isGenerating
                                   && message.role == .sophie
                                   && message.id == model.messages.last?.id)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, SophieDesign.screenPadding)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.last?.text) {
                if let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: inputFocused) {
                guard inputFocused, let last = model.messages.last else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let error = model.errorMessage {
                    Text(error)
                        .font(SophieDesign.captionFont)
                        .foregroundStyle(SophieDesign.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SophieDesign.screenPadding)
                }
                inputBar
            }
            .background(SophieDesign.background)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(SophieDesign.textPrimary.opacity(0.10))
                    .frame(height: 1)
            }
        }
        .background(SophieDesign.background)
        .preferredColorScheme(.dark)   // канон дизайна: тема одна, тёмная
        .task {
            // Прогрев (поле 22.08): первый вопрос платил за холодную
            // загрузку модели десятками секунд — грузим, пока печатают
            if model.gateOpen {
                _ = try? await ModelScheduler.shared.preload()
            }
        }
    }

    // Линейка состояний ответа (мокап sophie_stopped): думает — три точки в
    // пустом пузыре; печатает — текст растёт, каретка в конце; остановлено —
    // слабая обводка + торцевой маркер + «Продолжить» (генерация с
    // частичного ответа как префикса ассистента, тёплый KV).
    private func bubble(_ message: SophieMessage, isStreaming: Bool) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                if message.isStatusCard {
                    // WP3: карточка статуса — собрана кодом, не моделью
                    Label("Состояние связи",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SophieDesign.sophieLight)
                    Divider().overlay(SophieDesign.textPrimary.opacity(0.08))
                }
                if message.text.isEmpty && isStreaming {
                    SophieTypingDots()                       // «думает»
                } else {
                    (Text(message.text)
                     + Text(isStreaming ? " ▍" : "")       // каретка «печатает»
                        .foregroundColor(SophieDesign.sophie))
                        .font(SophieDesign.messageFont)
                        .lineSpacing(15 * 0.45)            // 15/1.45 из токенов
                        .foregroundStyle(message.role == .user
                                         ? SophieDesign.sophieTextStrong
                                         : SophieDesign.sophieText)
                        .textSelection(.enabled)
                }
                if message.isStopped {
                    Divider()
                        .overlay(SophieDesign.textPrimary.opacity(0.08))
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(SophieDesign.sophieLight.opacity(0.75))
                            .frame(width: 9, height: 9)
                        Text("ОСТАНОВЛЕНО ВАМИ · ОТВЕТ НЕПОЛНЫЙ")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.22)
                            .foregroundStyle(SophieDesign.sophieLight.opacity(0.75))
                        Spacer(minLength: 8)
                        // Место заложено дизайном (мокап sophie_stopped) —
                        // теперь с функцией: продолжение с тёплого KV
                        Button {
                            model.continueGeneration(message.id)
                        } label: {
                            Text("Продолжить")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(SophieDesign.sophieLight)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .overlay(Capsule()
                                    .strokeBorder(SophieDesign.sophie.opacity(0.5),
                                                  lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .disabled(model.isGenerating || !model.gateOpen)
                    }
                }
            }
            .padding(.horizontal, SophieDesign.bubblePaddingH)
            .padding(.vertical, SophieDesign.bubblePaddingV)
            .background(message.role == .user
                        ? SophieDesign.sophieSurface          // свой: #1b3b58
                        : SophieDesign.sophieBubbleIn)        // Софи: #1a2836
            .clipShape(BubbleShape(ownSide: message.role == .user))
            .overlay {
                if message.isStopped {                    // слабая обводка
                    BubbleShape(ownSide: false)
                        .stroke(SophieDesign.sophie.opacity(0.22), lineWidth: 1)
                }
            }
            if message.role == .sophie { Spacer(minLength: 40) }
        }
    }

    // Гейт локальной модели по мокапу sophie_local_only_gate: щит-замок,
    // объяснение приватности, карточка фактического профиля (реальные
    // данные, не макетные), outline-кнопка перехода во вкладку Dev.
    private var localOnlyGate: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()

            RoundedRectangle(cornerRadius: 16)
                .fill(SophieDesign.sophieSurface)
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(SophieDesign.sophie, lineWidth: 1.5))
                .overlay(Image(systemName: "lock.shield")
                    .font(.system(size: 26))
                    .foregroundStyle(SophieDesign.sophieLight))

            Text("\(AppIdentity.assistantName) работает только с локальной моделью")
                .font(.system(size: 22, weight: .medium))
                .kerning(-0.4)
                .foregroundStyle(SophieDesign.sophieText)

            Text("Разговоры с \(AppIdentity.assistantName) не покидают устройство — поэтому чат "
               + "доступен только когда отвечает модель, установленная "
               + "на телефоне.")
                .font(.system(size: 13.5))
                .lineSpacing(13.5 * 0.6)
                .foregroundStyle(SophieDesign.textSecondary)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Circle().fill(SophieDesign.sophie).frame(width: 8, height: 8)
                    Text("Сейчас активен сетевой профиль")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SophieDesign.sophieText)
                }
                gateInfoRow("Провайдер",
                            LLMModelConfig.loadActive().displayName)
                Divider().overlay(SophieDesign.textPrimary.opacity(0.08))
                gateInfoRow("Локальная модель",
                            ModelStore.installedModels().first
                                .map { $0.lastPathComponent + " · установлена" }
                            ?? "не найдена — установите в Настройках → Помощник")
            }
            .padding(13)
            .background(Color(hex: 0x132436))   // sophie-card из токенов
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SophieDesign.sophie.opacity(0.35), lineWidth: 1))

            VStack(alignment: .leading, spacing: 9) {
                Button {
                    // Баг 02.08: раньше кнопка вела в Dev («переключение
                    // вручную»), хотя модель уже стояла. Теперь: модель
                    // установлена → профиль переключается ЗДЕСЬ, одним
                    // тапом; не установлена → ведём в Настройки→Помощник.
                    if LLMModelConfig.activateLocalIfInstalled() != nil {
                        model.refreshGate()
                    } else {
                        router.selection = .settings
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Переключить на локальную модель")
                            .font(.system(size: 14.5, weight: .medium))
                        Text("›")
                            .foregroundStyle(SophieDesign.sophieLight.opacity(0.7))
                    }
                    .foregroundStyle(SophieDesign.sophieLight)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 48)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SophieDesign.sophie, lineWidth: 1))
                }
                Text("Модель установлена — переключение произойдёт сразу. "
                   + "Если модели нет, откроются Настройки → Помощник.")
                    .font(.system(size: 11.5))
                    .lineSpacing(11.5 * 0.5)
                    .foregroundStyle(SophieDesign.textTertiary)
            }

            Text("Пресет-чаты, история и черновики сохранены — вернутся, "
               + "как только провайдер снова станет локальным.")
                .font(.system(size: 11.5))
                .lineSpacing(11.5 * 0.5)
                .foregroundStyle(SophieDesign.textTertiary)

            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SophieDesign.background)
    }

    private func gateInfoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(SophieDesign.sophieText.opacity(0.55))
            Spacer()
            Text(value)
                .font(.system(size: 12.5))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(SophieDesign.sophieText)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
        HStack(spacing: 8) {
            if model.isDictating, model.dictation.isRecognizing {
                // после ■: файл в распознавателе
                DictationProcessingBar(label: "распознаю…")
            } else if model.isDictating {
                // Запись: × — волна+таймер — ■ на месте mic; отправка
                // скрыта, текста нет ни в каком виде (state-машина)
                DictationRecordingBar(
                    levels: model.dictation.levels,
                    elapsed: model.dictation.elapsed,
                    accent: SophieDesign.sophie,
                    onCancel: { model.cancelDictation() },
                    onStop: { model.dictation.stopAndDeliver() })
            } else {
            HStack(spacing: 4) {
                TextField("Сообщение \(AppIdentity.assistantName)…", text: $model.input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .font(SophieDesign.messageFont)
                    .foregroundStyle(SophieDesign.textPrimary)
                    .onSubmit { model.send() }
                Button {
                    model.micTapped()
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 17))
                        .foregroundStyle(model.dictation.unavailableHint == nil
                                         ? SophieDesign.textSecondary
                                         : SophieDesign.textPrimary.opacity(0.25))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Диктовка")
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .frame(minHeight: SophieDesign.controlSize)
            .background(SophieDesign.surface1)   // капсула на поверхности 1
            .clipShape(RoundedRectangle(cornerRadius: SophieDesign.fieldRadius))

            Group {
                if model.isGenerating {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(SophieDesign.sophieLight)
                            .frame(width: SophieDesign.controlSize,
                                   height: SophieDesign.controlSize)
                            .background(SophieDesign.sophieSurface)
                            .clipShape(Circle())
                    }
                } else {
                    Button {
                        model.send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .fontWeight(.semibold)
                            .foregroundStyle(SophieDesign.sophieLight)
                            .frame(width: SophieDesign.controlSize,
                                   height: SophieDesign.controlSize)
                            .background(SophieDesign.sophieSurface)
                            .clipShape(Circle())
                    }
                    .disabled(model.input.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty
                        || !model.gateOpen)
                }
            }
            }
        }
        // Полоса композера: 8 12 30 из токенов (30 — под home-indicator)
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .padding(.bottom, model.dictationHint != nil ? 2 : 8)
        .onAppear { model.dictation.checkSupport() }

        if !model.gateOpen, model.preset == .sos {
            // SOS-чат виден и без модели (Ф1.4) — но разговор с Софи
            // требует её; карточка SOS выше работает без модели
            Text("Помощник не установлен — разговор недоступен, "
               + "но карточка SOS работает: заполните её руками.")
                .font(.system(size: 11.5))
                .foregroundStyle(RMDesign.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }

        if let hint = model.dictationHint {
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(RMDesign.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }
        }
    }
}

/// Три точки «думает» (мокап sophie_thinking): пульсация со сдвигом фазы.
struct SophieTypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(SophieDesign.sophie)
                    .frame(width: 5, height: 5)
                    .opacity(animating ? 1 : 0.3)
                    .offset(y: animating ? -3 : 0)
                    .animation(.easeInOut(duration: 0.55)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.18), value: animating)
            }
        }
        .padding(.vertical, 4)
        .onAppear { animating = true }
    }
}

#Preview {
    SophieChatView()
        .environmentObject(TabRouter())
}
