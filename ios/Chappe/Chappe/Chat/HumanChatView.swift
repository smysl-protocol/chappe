//
//  HumanChatView.swift
//  R+M — демо-чат с человеком + шёпот @Софи (sophie_presence §3, фаза 2б).
//
//  Композер: три состояния по мокапам (normal / autocomplete / whisper).
//  Шёпот: вопрос и ответ видит только пользователь; ветка НЕ проходит
//  через очередь envelope (другой путь данных — гарантия кода, §3 п.2);
//  «В черновик» — единственный путь шёпота в сообщение (§3 п.3).
//  Исходящие — честный offline-first: envelope TEXT в очередь, статус
//  «в очереди · узлов нет».
//

import SwiftUI
import Combine
import UIKit

@MainActor
final class HumanChatModel: ObservableObject {

    @Published var entries: [ChatEntry] = []
    @Published var draft: String = HumanChatStore.draft {
        didSet { HumanChatStore.draft = draft }
    }
    @Published var suggesting = false      // плашка «@Софи · спросить локально»
    @Published var whisperMode = false     // чип создан, композер синий
    @Published var isWhisperGenerating = false
    @Published var gateOpen = ModelScheduler.isLocalProviderActive()
    /// Язык развёртки пузырей (Dev-тумблер RU/EN); обновляется в reload.
    @Published var unfoldLanguage = RMCodec.unfoldLanguage
    @Published var isEncoding = false      // семантика: модель готовит пивот

    // MARK: Оптимизатор текста (часть 2 брифа 08.08)

    /// Исходный вариант человека, пока в поле лежит оптимизированный —
    /// по нему работает откат «как сказал». Любая РУЧНАЯ правка обнуляет
    /// его: дальше текст считается новым, и откат исчезает. Так потерять
    /// написанное человеком нельзя в принципе (требование владельца).
    @Published private(set) var optimizerOriginal: String?
    /// Выигрыш показываем только в пакетах и только когда их стало меньше.
    @Published private(set) var optimizerWin: (before: Int, after: Int)?
    @Published var isOptimizing = false
    /// Честная строка нерабочего исхода сокращения — показывается ПОД
    /// полем ввода (полевой прогон 19.08: строка вычислялась, но нигде
    /// не рисовалась — кнопка выглядела сломанной). Гаснет при ручной
    /// правке текста.
    @Published private(set) var optimizerRejection: String?

    /// Только для тестов: поставить причину отказа без прогона модели.
    func setRejectionForTests(_ line: String) { optimizerRejection = line }

    /// Показывать ли иконку оптимизации вместо микрофона.
    var optimizerOffered: Bool {
        dictationState == .idle && !whisperMode && !isOptimizing
            && (optimizerOriginal != nil
                || TextOptimizer.worthOffering(draft))
    }

    /// В поле лежит оптимизированный вариант — кнопка работает откатом.
    var optimizerShowingShort: Bool { optimizerOriginal != nil }

    /// Только для тестов: поставить состояние «в поле лежит короткий
    /// вариант» без прогона модели.
    func applyOptimizedForTests(text: String, original: String,
                                before: Int, after: Int) {
        let previous = draft
        programmaticEdit = true
        draft = text
        // в живом экране флаг съедает onChange поля; в тесте делаем это
        // руками, иначе следующая правка ошибочно сойдёт за программную
        draftEdited(old: previous, new: text)
        optimizerOriginal = original
        optimizerWin = (before, after)
    }

    func optimizerTapped() {
        // откат «как короче» → «как сказал»
        if let original = optimizerOriginal {
            programmaticEdit = true
            draft = original
            optimizerOriginal = nil
            optimizerWin = nil
            return
        }
        let source = draft
        guard !source.isEmpty else { return }
        isOptimizing = true
        optimizerRejection = nil
        Task { @MainActor in
            let outcome = await TextOptimizer.optimize(source)
            isOptimizing = false
            // человек успел изменить текст, пока модель думала — не трогаем
            guard draft == source else { return }
            switch outcome {
            case .optimized(let text, let before, let after):
                programmaticEdit = true
                draft = text
                optimizerOriginal = source
                optimizerWin = (before, after)
            default:
                // тишина не есть отказ (полевой прогон 08.08: без
                // помощника кнопка молчала — «оптимизатор не работает»)
                optimizerRejection = Self.optimizerFeedback(outcome)
            }
        }
    }
    /// Честная строка каждому нерабочему исходу сокращения — молчание
    /// читается как поломка. Чистая функция — под замком тестов.
    nonisolated static func optimizerFeedback(_ outcome: TextOptimizer.Outcome)
    -> String? {
        switch outcome {
        case .optimized: nil
        case .rejected(let reason): reason
        case .noGain: "короче не получилось — текст уже плотный"
        case .unavailable: "нужен помощник: установите или включите его "
            + "в Настройках → Помощник"
        }
    }

    /// Карточка SOS открыта командой «@Софи SOS» (Ф3.6).
    @Published var showSOSDraft = false

    // MARK: Одобрение инлайн (semantic_compression §4 — в композере)

    /// Режим отправки одобренного: смысловыми кодами или текстом.
    enum ApprovalMode { case semantic, text }

    /// Готовый итог конвейера. Инвариант: в режиме semantic поле ввода
    /// показывает РАЗВЁРНУТЫЙ текст получателя (round-trip байт), в
    /// режиме text — исходник, уйдёт как есть. Человек всегда видит
    /// ровно то, что увидит получатель.
    struct Approval {
        var semantic: SemanticEncoder.Encoded?
        var reason: String?        // причина текстового отката (gate/модель)
        var textPackets: Int
        var mode: ApprovalMode
        var sourceText: String     // текст, из которого считали
    }
    @Published var approval: Approval?
    @Published var isRecalculating = false   // бейдж «пересчитываю…»
    private var recalcGen = 0                // защита от гонок пересчётов
    private var recalcTask: Task<Void, Never>?
    private var confirmAfterRecalc = false   // отправка ждёт пересчёт
    /// Б2 (29.07): человек правил распознанный текст РУКАМИ — его
    /// правка авторитетна: уходит дословно текстом, если семантический
    /// рендер не совпал посимвольно.
    private(set) var editedAfterDictation = false
    /// Текущее одобрение родилось из диктовки (Б2 действует только там).
    private var approvalFromDictation = false

    /// Конвейер как зависимость — тесты подменяют на детерминированный.
    /// Сегменты пауз последней диктовки — сегментатор источника для
    /// смешанного режима; очищается при ручном наборе.
    var lastPauseSegments: [String] = []
    var pipeline: (String) async -> SemanticEncoder.Outcome = {
        await SemanticEncoder.prepare(russian: $0)
    }
    /// Debounce правки перед пересчётом; тесты укорачивают.
    var recalcDebounceMillis = 800

    /// Флаг программной вставки («В черновик»): такие изменения текста
    /// НЕ создают подсказку (§3.1 — только ручной ввод с клавиатуры).
    private var programmaticEdit = false
    private var whisperTask: Task<Void, Never>?

    // MARK: Диктовка — state-машина: idle → recording → processing → review
    // Партиалы копятся ТОЛЬКО в буфер SpeechDictation, поле ввода во
    // время записи заменено индикатором (волна + таймер). По ■ буфер
    // идёт в семантический конвейер (review = существующее одобрение);
    // в режиме шёпота — просто в поле, вопрос Софи не кодируется.
    // Голосом токен шёпота создать нельзя (§3.1): вставка программная.

    enum DictationState: Equatable { case idle, recording, processing }
    @Published var dictationState: DictationState = .idle
    let dictation = SpeechDictation()
    @Published var dictationHint: String?
    private var draftBeforeRecording = ""

    func micTapped() {
        guard dictationState == .idle else { return }
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
                dictationState = .idle
                dictationHint = dictation.unavailableHint
            }
        }
    }

    /// Снимок состояния до записи (тестируется отдельно от AVAudio).
    func dictationDidStart() {
        draftBeforeRecording = draft
        dictationState = .recording
        editedAfterDictation = false
    }

    /// × — буфер в мусор, композер как был до записи.
    func cancelDictation() {
        dictation.cancel()
        dictationState = .idle
    }

    /// ■ — распознанный файл целиком: шёпот — в поле (без кодирования,
    /// оно только для эфира); обычный чат — в полный конвейер → review.
    func dictationDidFinish(_ text: String) {
        guard dictationState == .recording else { return }
        // П5: времена STT правим до конвейера («уже 02:00» → «уже 2 часа»,
        // «в семь тридцать» → «в 07:30»)
        let trimmed = STTNormalizer.normalizeTimes(
            text.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.isEmpty, let failure = dictation.recognitionFailure {
            dictationHint = failure   // честно сказать, что не вышло
        }
        let full = draftBeforeRecording.isEmpty || trimmed.isEmpty
            ? (draftBeforeRecording + trimmed)
            : draftBeforeRecording + " " + trimmed
        if whisperMode || trimmed.isEmpty {
            programmaticEdit = true
            draft = full
            dictationState = .idle
            return
        }
        programmaticEdit = true
        draft = full
        lastPauseSegments = dictation.lastPauseSegments
        dictationState = .processing   // спиннер «обрабатываю…»
        approvalFromDictation = true   // Б2 действует только для диктовки
        startApproval()                // → review (бейдж + развёрнутый текст)
    }

    private var dictationSync: AnyCancellable?

    /// nil — демо-собеседник; иначе живой контакт (веха, фаза 2).
    let contact: Contact?
    var contactID: String? { contact?.id }

    init(contact: Contact? = nil) {
        self.contact = contact
        // сегменты пауз доступны конвейеру (сегментатор смешанного
        // режима); тесты по-прежнему подменяют pipeline целиком
        pipeline = { [weak self] text in
            // А1 (09.08): пивот только для LoRa — единственного пути,
            // где байты дороже секунд. Быстрые транспорты (релей, BLE
            // «рядом», Wi-Fi Aware) идут текстом без модели: замер на
            // живом Release — модель 2,4–4,8 с, весь быстрый путь
            // 14,5 мс. Сосед рядом больше НЕ повод ждать модель.
            let worth = await MainActor.run {
                SendPolicy.pivotWorthRunning(
                    hasContact: self?.contact != nil,
                    loRaConfigured: DeliveryManager.shared.radioReady,
                    nearbyNow: DeliveryManager.shared.nearbyReady)
            }
            guard worth else {
                return .text(reason: SendPolicy.skipReason, needsCard: false)
            }
            return await SemanticEncoder.prepare(
                russian: text,
                pauseSegments: self?.lastPauseSegments ?? [])
        }
        reload()
        // ■ → файл распознан → текст одним куском
        dictation.onFinished = { [weak self] text in
            self?.dictationDidFinish(text)
        }
        // волна/таймер/фаза «распознаю…» живут в SpeechDictation —
        // пробрасываем её изменения в объект модели, иначе UI застынет
        dictationSync = dictation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func reload() {
        // открыли чат — входящие в нём считаются прочитанными
        HumanChatStore.markRead(contactID: contactID)
        DeliveryManager.shared.sendReadReceipts(contactID: contactID)
        gateOpen = ModelScheduler.isLocalProviderActive()
        unfoldLanguage = RMCodec.unfoldLanguage
        let log = HumanChatStore.loadLog(contactID: contactID)
        let whispers = HumanChatStore.loadWhispers(contactID: contactID)
        entries = (log + whispers).sorted { $0.date < $1.date }
    }

    // MARK: Композер (§3.1)

    func draftEdited(old: String, new: String) {
        let programmatic = programmaticEdit
        programmaticEdit = false
        // Ручная правка после оптимизации: текст становится новым, откат
        // исчезает. Иначе откат вернул бы вариант ДО правки и стёр только
        // что дописанное — худшее, что может сделать строка ввода.
        if !programmatic, optimizerOriginal != nil {
            optimizerOriginal = nil
            optimizerWin = nil
        }
        // Человек правит текст — прежний отказ оптимизатора устарел
        if !programmatic, optimizerRejection != nil {
            optimizerRejection = nil
        }
        if whisperMode { suggesting = false; return }

        // Ручная правка при готовом/считающемся одобрении → пересчёт
        // с debounce; пустое поле — одобрение снимается совсем.
        if !programmatic, approval != nil || isRecalculating || isEncoding {
            if approvalFromDictation {
                editedAfterDictation = true  // Б2: правка руками ПОСЛЕ диктовки
            }
            if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cancelApproval()
            } else {
                scheduleRecalc()
            }
        }

        if WhisperTrigger.shouldSuggest(old: old, new: new,
                                        programmatic: programmatic) {
            suggesting = true
        } else if suggesting,
                  !(new.split(separator: " ", omittingEmptySubsequences: false)
                        .last?.hasPrefix("@") ?? false) {
            suggesting = false
        }
    }

    /// Принятие подсказки (тап) — ЕДИНСТВЕННЫЙ путь в режим шёпота.
    /// Цвет меняется в этот момент, не при вводе «@» (решение дизайна).
    func acceptSuggestion() {
        guard suggesting else { return }
        programmaticEdit = true
        draft = WhisperTrigger.textAfterAccept(draft)
        suggesting = false
        whisperMode = true
    }

    /// ✕ на чипе — мгновенный возврат обычного режима.
    func dismissChip() {
        whisperMode = false
    }

    /// «В черновик» из ответа Софи — программная вставка: режим шёпота
    /// НЕ включается, подсказка не появляется.
    func insertDraft(_ text: String) {
        programmaticEdit = true
        draft = text
    }

    // MARK: Отправка

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Команда «@Софи SOS» (3.6): открывает карточку-черновик SOS —
        // текст команды НЕ уходит в эфир и не попадает в ленту.
        // Работает и целиком набранная, и как «SOS» в режиме шёпота.
        if SOSCommand.isMentionCommand(text)
            || (whisperMode && SOSCommand.isCommand(text)) {
            programmaticEdit = true
            draft = ""
            whisperMode = false
            showSOSDraft = true
            return
        }
        if whisperMode {
            programmaticEdit = true
            draft = ""
            whisperMode = false
            whisperTask = Task { await whisper(text) }
            return
        }
        if approval == nil {
            // Первый тап: конвейер; поле подменится текстом получателя
            startApproval()
        } else if recalcTask != nil || isEncoding {
            // Правка ещё пересчитывается — отправим по завершении (без гонки)
            confirmAfterRecalc = true
        } else {
            // Второй тап (галочка): одобрено — отправляем
            sendApproved()
        }
    }

    func stopWhisper() {
        Task { await ModelScheduler.shared.cancelActive() }
    }

    // MARK: Отправка: одобрение инлайн (semantic_compression §4)

    /// Запуск конвейера от текущего текста поля. По готовности:
    /// семантика — поле подменяется развёрнутым текстом получателя,
    /// бейдж «✓ так увидит получатель»; откат — бейдж «текстом», текст
    /// не подменяется.
    func startApproval() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isEncoding else { return }
        recalcTask?.cancel()
        recalcTask = nil
        isRecalculating = false
        isEncoding = true
        recalcGen += 1
        let gen = recalcGen
        Task {
            await runPipeline(text: text, gen: gen, keepTextMode: false)
            isEncoding = false
            if dictationState == .processing {
                dictationState = .idle   // processing → review (бейдж готов)
            }
            if gen == recalcGen, confirmAfterRecalc {
                confirmAfterRecalc = false
                sendApproved()
            }
        }
    }

    /// Правка одобренного: debounce → повторный конвейер от текущего
    /// текста. Устаревшие пересчёты гасятся поколением (без гонки).
    private func scheduleRecalc() {
        recalcGen += 1
        let gen = recalcGen
        isRecalculating = true
        recalcTask?.cancel()
        recalcTask = Task {
            try? await Task.sleep(for: .milliseconds(recalcDebounceMillis))
            guard gen == recalcGen else { return }
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                cancelApproval()
                return
            }
            // выбор человека «текстом» переживает пересчёт
            let keepText = approval?.mode == .text
            await runPipeline(text: text, gen: gen, keepTextMode: keepText)
            guard gen == recalcGen else { return }
            isRecalculating = false
            recalcTask = nil
            if confirmAfterRecalc {
                confirmAfterRecalc = false
                sendApproved()
            }
        }
    }

    private func runPipeline(text: String, gen: Int, keepTextMode: Bool) async {
        let textPackets = (try? TextEncoder.encode(
            msgID: 0, text: text, wantAck: true).count) ?? 1
        let outcome = await pipeline(text)
        // Авто-корпус (п.3, 31.07): дозаполнить запись диктовки итогом
        // конвейера — пивот, байты, рендер, решение гейта
        if let cid = SpeechDictation.lastCorpusID {
            SpeechDictation.lastCorpusID = nil
            switch outcome {
            case .semantic(let e):
                DictationCorpus.complete(id: cid, pivot: e.pivot,
                                         blob: e.blob, rendered: e.rendered,
                                         decision: "semantic", reason: nil)
            case .text(let reason, _):
                // пропуск пивота политикой — не решение гейтов: пометка
                // отдельная, тексты добираются пивотами на ферме (WP1)
                DictationCorpus.complete(
                    id: cid, pivot: nil, blob: nil, rendered: nil,
                    decision: reason == SendPolicy.skipReason
                        ? SendPolicy.skipDecision : "text",
                    reason: reason)
            }
        }
        guard gen == recalcGen else { return }   // устаревший обсчёт
        switch outcome {
        case .semantic(let encoded):
            // Б2: ручная правка авторитетна — семантикой только если
            // рендер посимвольно совпал с текстом человека
            if editedAfterDictation, encoded.rendered != text {
                approval = Approval(semantic: nil,
                                    reason: "точно как написано",
                                    textPackets: textPackets, mode: .text,
                                    sourceText: text)
                return
            }
            approval = Approval(semantic: encoded, reason: nil,
                                textPackets: textPackets,
                                mode: keepTextMode ? .text : .semantic,
                                sourceText: text)
            if !keepTextMode {
                // Поле = ровно то, что увидит получатель (курсор в конец)
                programmaticEdit = true
                draft = encoded.rendered
            }
        case .text(let reason, _):
            // TEXT-откат: текст НЕ подменяется, бейдж честно говорит режим
            approval = Approval(semantic: nil, reason: reason,
                                textPackets: textPackets, mode: .text,
                                sourceText: text)
        }
    }

    /// Тап по бейджу — переключатель «смыслами/текстом». Поле всегда
    /// показывает то, что уйдёт: смыслами — развёрнутый текст, текстом —
    /// исходник.
    func toggleApprovalMode() {
        guard var a = approval, recalcTask == nil, !isEncoding else { return }
        switch a.mode {
        case .semantic:
            a.mode = .text
            approval = a
            programmaticEdit = true
            draft = a.sourceText
        case .text:
            if let semantic = a.semantic {
                a.mode = .semantic
                approval = a
                programmaticEdit = true
                draft = semantic.rendered
            } else {
                // семантики не было (gate/модель) — честная новая попытка
                isEncoding = true
                recalcGen += 1
                let gen = recalcGen
                let text = a.sourceText
                Task {
                    await runPipeline(text: text, gen: gen, keepTextMode: false)
                    isEncoding = false
                }
            }
        }
    }

    /// Полный сброс одобрения (поле опустело).
    func cancelApproval(resetEdited: Bool = true) {
        if resetEdited {
            editedAfterDictation = false
            approvalFromDictation = false
        }
        recalcGen += 1
        recalcTask?.cancel()
        recalcTask = nil
        isRecalculating = false
        isEncoding = false
        confirmAfterRecalc = false
        approval = nil
    }

    /// Второй тап (галочка): в эфир уходит ровно то, что в поле.
    private func sendApproved() {
        guard let a = approval else { return }
        let fieldText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        approval = nil
        programmaticEdit = true
        draft = ""
        if a.mode == .semantic, let encoded = a.semantic {
            // Residual-счётчик: только подтверждённые человеком отправки
            // (semantic_compression §6 — рост словаря по факту использования)
            ResidualCounter.record(units: encoded.units)
            var entry = ChatEntry(kind: .outgoing, text: encoded.rendered,
                                  status: "отправляется…")
            // wire-форма ([хеш таблицы][блоб]) — единая для провода и
            // хранения: развёртка сверяет версию словаря (п.5)
            let wire = RMCodec.shared?.wireBlob(encoded.blob) ?? encoded.blob
            entry.semanticBlob = wire   // для развёртки RU/EN в ленте
            // WP1: сообщение в хранилище ДО попытки отправки — падение
            // кодека/очереди/приложения не может его стереть
            entries.append(entry)
            HumanChatStore.upsertLog(entry, contactID: contactID)
            do {
                let queued: Outbox.QueuedMessage
                if let contact {
                    // адресное: sealed box, на проводе только байты
                    queued = try Outbox.enqueueSealed(
                        innerCodec: Envelope.codecSemantic,
                        data: wire, to: contact, entryID: entry.id)
                } else {
                    queued = try Outbox.enqueueSemantic(blob: wire,
                                                        entryID: entry.id)
                }
                // Б7: размер блоба и кратность сжатия — прямо в статусе.
                // Путь доставки вместо счётчика узлов (05.08): для
                // большинства пользователей узла нет и не будет, а
                // «узлов нет» выглядело как поломка приложения
                let srcBytes = a.sourceText.utf8.count
                let ratio = queued.totalBytes > 0
                    ? Double(srcBytes) / Double(queued.totalBytes) : 1
                entry.status = "сжато \(srcBytes)→\(queued.totalBytes) Б"
                             + String(format: " (%.1f×)", ratio)
                             + " · \(queued.packetsHex.count) пакет"
                             + " · " + DeliveryManager.shared.pathSummary
                entry.envelopeBytes = queued.totalBytes
                entry.wireMsgID = Int(queued.msgID)
            } catch {
                entry.status = "не закодировалось: \(error.localizedDescription)"
            }
            if let i = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[i] = entry
            }
            // upsert, не перезапись: снимок entries может не знать про
            // входящие, дописанные DeliveryManager (причина регрессии)
            HumanChatStore.upsertLog(entry, contactID: contactID)
            DeliveryManager.shared.pushQueue()
            // Позиционный маячок по событию «сообщение ушло» (WP7):
            // молчит без гранта, лимита и фикса — вся политика внутри
            if let contact { PositionBeacon.shared.afterMessageSent(to: contact.id) }
        } else {
            sendPlainText(fieldText.isEmpty ? a.sourceText : fieldText)
        }
    }

    func sendPlainText(_ text: String) {
        // internal, не private — тест-замок регрессии зовёт напрямую
        var entry = ChatEntry(kind: .outgoing, text: text,
                              status: "отправляется…")
        // WP1: в хранилище ДО попытки отправки (см. sendApproved)
        entries.append(entry)
        HumanChatStore.upsertLog(entry, contactID: contactID)
        do {
            let queued: Outbox.QueuedMessage
            if let contact {
                // гейт размера: store против zlib, меньший побеждает
                let (codec, data) = TextCodec.best(text)
                queued = try Outbox.enqueueSealed(
                    innerCodec: codec, data: data,
                    to: contact, entryID: entry.id)
            } else {
                queued = try Outbox.enqueue(text: text, entryID: entry.id)
            }
            let packets = queued.packetsHex.count
            // путь доставки вместо счётчика узлов — см. sendApproved
            entry.status = "текст · \(queued.totalBytes) Б · "
                         + "\(packets) пакет\(packets == 1 ? "" : packets < 5 ? "а" : "ов")"
                         + " · " + DeliveryManager.shared.pathSummary
            entry.envelopeBytes = queued.totalBytes
            entry.wireMsgID = Int(queued.msgID)
        } catch {
            entry.status = "не закодировалось: \(error.localizedDescription)"
        }
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        }
        HumanChatStore.upsertLog(entry, contactID: contactID)   // не снимком
        DeliveryManager.shared.pushQueue()
        // Позиционный маячок по событию «сообщение ушло» (WP7)
        if let contact { PositionBeacon.shared.afterMessageSent(to: contact.id) }
    }

    // MARK: Шёпот (§3.2): контекст переписки + инструменты, P2

    private func whisper(_ question: String) async {
        isWhisperGenerating = true
        var q = ChatEntry(kind: .whisperQuestion, text: question)
        var a = ChatEntry(kind: .whisperAnswer, text: "")
        entries.append(q)
        entries.append(a)
        let answerID = a.id
        // WP1: вопрос — в хранилище сразу; краш генерации его не съест
        HumanChatStore.upsertWhisper(q, contactID: contactID)
        _ = q; _ = a

        defer {
            isWhisperGenerating = false
            // upsert ответа по id, не перезапись файла снимком entries
            if let i = entries.firstIndex(where: { $0.id == answerID }) {
                HumanChatStore.upsertWhisper(entries[i],
                                             contactID: contactID)
            }
        }

        // Перехват ДО модели (Ф6): вопрос целиком о дате/времени/дне
        // недели отвечает код, модель не вызывается
        if let direct = SophieClock.directAnswer(for: question) {
            set(text: direct, for: answerID)
            return
        }

        do {
            // Инструменты доступны и в шёпоте (§3.2 → §4)
            let toolBlock = await SophieChatModel.toolBlockIfNeeded(for: question)

            // Контекст: последние сообщения, но с токен-бюджетом (~1200):
            // безразмерный транскрипт раздувал промпт (крэш 28.07 —
            // prefill длиннее n_batch; чанки в LlamaRuntime это чинят,
            // бюджет — страховка сверху и защита скорости prefill)
            var transcriptLines: [String] = []
            var transcriptBudget = 1200
            for entry in entries.filter({ $0.kind == .outgoing }).suffix(12)
                .reversed() {
                let line = "Я собеседнику: \(entry.text)"
                let cost = SophiePrompt.estimatedTokens(line)
                if transcriptBudget - cost < 0 { break }
                transcriptBudget -= cost
                transcriptLines.append(line)
            }
            let transcript = transcriptLines.reversed().joined(separator: "\n")

            var user = ""
            if !transcript.isEmpty {
                user += "Переписка с человеком (для контекста):\n\(transcript)\n\n"
            }
            if let toolBlock { user += toolBlock + "\n" }
            // Данные устройства — на каждом ходе (Ф6)
            user += SophieClock.nowLine() + "\n"
            user += "Вопрос пользователя (шёпотом, собеседник не видит): " + question

            let system = try SophiePrompt.systemPrompt()
                + "\n\nСейчас это ШЁПОТ внутри чата с человеком: твой ответ "
                + "видит только пользователь, собеседнику ничего не уходит. "
                + "Отвечай кратко; если уместно — предложи формулировку "
                + "сообщения собеседнику."

            let request = LLMRequest(prompt: user, systemPrompt: system,
                                     maxTokens: 300)
            let response = try await ModelScheduler.shared
                .withProvider(.interactive) { provider in
                    try await provider.generateStreaming(request) { chunk in
                        Task { @MainActor in
                            self.append(chunk: chunk, to: answerID)
                        }
                    }
                }
            // Пост-валидатор дат (Ф6): расхождение подменяется, факт в лог
            let gated = SophieClock.validated(response.text)
            SophieClock.logMismatches(gated.mismatches, context: "шёпот")
            set(text: gated.text, for: answerID)
        } catch {
            if case LLMError.cancelled = error {
                markStopped(answerID)
            } else {
                set(text: "Не получилось ответить: "
                    + ((error as? LocalizedError)?.errorDescription
                       ?? error.localizedDescription), for: answerID)
            }
        }
    }

    private func append(chunk: String, to id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].text += chunk
    }

    private func set(text: String, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].text = text
    }

    private func markStopped(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[i].text.isEmpty {
            entries.remove(at: i)
        } else {
            entries[i].stopped = true
        }
    }

    /// «Скрыть» на карточке шёпота: убрать запись из приватной ветки.
    func hideWhisper(_ id: UUID) {
        entries.removeAll { $0.id == id }
        HumanChatStore.removeWhisper(id: id, contactID: contactID)  // не снимком
    }
}

// MARK: - Экран

struct HumanChatView: View {

    /// Строка чипа позиции собеседника — чистая, под замком (мега-5).
    nonisolated static func peerPositionLine(fixAge: TimeInterval) -> String {
        let age = max(0, fixAge)
        if age < 60 { return "Позиция собеседника: только что · на карте" }
        if age < 3600 {
            return "Позиция собеседника: \(Int(age / 60)) мин назад · на карте"
        }
        return "Позиция собеседника: \(Int(age / 3600)) ч назад · на карте"
    }
    @StateObject private var model: HumanChatModel

    /// Подсказка пустой ленты. В чате живого контакта слова «Демо-чат»
    /// быть не должно (полевой прогон 08.08: подсказка демо в чате
    /// собеседника убедила владельца, что переписка «легла не туда»).
    nonisolated static func emptyFeedHint(isDemo: Bool) -> String {
        isDemo
            ? "Демо-чат: сообщения кодируются в пакеты и ждут дальней "
              + "связи. «@» в поле ввода — шёпот \(AppIdentity.assistantName)."
            : "Сообщений пока нет. Напишите первым — дойдёт по любому "
              + "живому пути. «@» в поле ввода — шёпот \(AppIdentity.assistantName)."
    }

    init(contact: Contact? = nil) {
        _model = StateObject(wrappedValue: HumanChatModel(contact: contact))
    }

    @FocusState private var inputFocused: Bool
    /// Пузыри с раскрытым «зеркалом получателя» (тап по своему
    /// семантическому сообщению).
    @State private var mirrorShown: Set<UUID> = []

    /// Активная SOS-сессия покрывает этого собеседника — чат
    /// подсвечен красным (3.5/3.6).
    @State private var sosActive = false
    /// Знакомство телефонов: предложение, системный лист и честный исход.
    @State private var offerPairing = false
    @State private var showPairingSheet = false
    @State private var pairingFailure: String?

    /// Тревога детектора клина узла — баннер над лентой.
    @State private var linkWarning: String?
    /// Позиция собеседника в чате (мега-5): чат читает тот же стор,
    /// что и карта.
    @ObservedObject private var peerPositions = PeerPositionStore.shared
    @EnvironmentObject private var router: TabRouter

    /// Сверка ключа из шапки чата (WP1): цель шита и тик перерисовки
    /// печати после отметки.
    @State private var verifyContact: Contact?
    @State private var trustTick = 0

    /// Печать доверия в шапке (WP1): состояние читается из хранилища
    /// при каждой перерисовке — снимок model.contact мог устареть.
    /// Предлагать ли знакомство телефонов прямо сейчас (правила — в
    /// NearbyPresence): контакт рядом, телефоны не знакомы, отказа не было.
    private func refreshPairingOffer() {
        guard let contact = model.contact, #available(iOS 26.0, *) else {
            offerPairing = false
            return
        }
        Task { @MainActor in
            // общий выключатель — см. NearbyPairing.uiEnabled (падение 08.08)
            guard NearbyPairing.uiEnabled else { offerPairing = false; return }
            let paired = await NearbyPairing.alreadyPaired()
            offerPairing = NearbyPresence.shared.shouldOfferPairing(
                contactID: contact.id, alreadyPaired: paired)
                && NearbyPairing.isSupported
        }
    }

    private func startPairing(with contact: Contact) {
        // согласился вручную — прежний отказ больше не мешает
        NearbyPresence.shared.clearDeclined(contactID: contact.id)
        pairingFailure = nil
        showPairingSheet = true
    }

    private func trustSeal(for contactID: String) -> some View {
        let verified = ContactStore.load()
            .first { $0.id == contactID }?.verified
        let (symbol, tint): (String, Color) = switch verified {
        case .some(true): ("checkmark.seal.fill", RMDesign.accentLight)
        case .some(false): ("exclamationmark.shield", RMDesign.warning)
        case nil: ("questionmark.diamond", RMDesign.textTertiary)
        }
        return Image(systemName: symbol)
            .foregroundStyle(tint)
            .id(trustTick)
    }

    var body: some View {
            // Лента НИКОГДА не прячется под композер: композер живёт в
            // safeAreaInset — ScrollView сам получает корректный inset
            // и при клавиатуре, и при росте поля до 5 строк
            feed
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if sosActive {
                            Label("SOS активен — контакт получил сигнал. "
                                  + "Отбой — в чате SOS.",
                                  systemImage: "light.beacon.max")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RMDesign.danger)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(RMDesign.danger.opacity(0.12))
                        }
                        // Тревога детектора клина (03.08): узел молчит,
                        // хотя копит, — сказать человеку, не молчать
                        if let warning = linkWarning {
                            Label(warning, systemImage:
                                "antenna.radiowaves.left.and.right.slash")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RMDesign.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(Color.orange.opacity(0.15))
                        }
                    }
                }
                .sheet(isPresented: $model.showSOSDraft, onDismiss: {
                    sosActive = SOSCenter.activeSessionCovers(
                        contactID: model.contact?.id)
                    model.reload()
                }) {
                    SOSDraftSheet(context: "")
                }
                .onAppear {
                    sosActive = SOSCenter.activeSessionCovers(
                        contactID: model.contact?.id)
                    refreshPairingOffer()
                }
                // собеседник может появиться рядом уже при открытом чате
                .onReceive(NearbyPresence.shared.$updates) { _ in
                    refreshPairingOffer()
                }
                .sheet(isPresented: $showPairingSheet, onDismiss: {
                    // исход проверяется фактом: появилось ли знакомство
                    Task { @MainActor in
                        let ok = await NearbyPairingOutcome.settled()
                        pairingFailure = NearbyPairingOutcome
                            .failureLine(pairedAfter: ok)
                        if ok { offerPairing = false }
                    }
                }) {
                    if #available(iOS 26.0, *) {
                        VStack(spacing: 0) {
                            NearbyPairingCaption()
                            NearbyPairingPicker { showPairingSheet = false }
                        }
                        .background(RMDesign.background)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 4) {
                        // геотрансляция (блок 5, 10.08): пока грант этому
                        // контакту жив — индикатор с остатком и отзывом.
                        // Право на раскрытие живёт в политике WP4 (Geo/),
                        // чат только читает её API и зовёт revoke
                        if FeatureFlags.geoInChat, let contact = model.contact {
                            LocationShareIndicator(contactID: contact.id)
                        }
                        // позиция СОБЕСЕДНИКА видна и В ЧАТЕ (мега-5,
                        // 14.08: раньше только карта читала стор — «включил,
                        // а в чате не видно»); тап — на карту
                        if FeatureFlags.geoInChat, let contact = model.contact,
                           let fix = peerPositions.positions[contact.id] {
                            Button {
                                router.selection = .map
                            } label: {
                                Label(Self.peerPositionLine(
                                        fixAge: -fix.timestamp
                                            .timeIntervalSinceNow),
                                      systemImage: "location.fill")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(RMDesign.accentLight)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(RMDesign.accentSurface)
                                    .clipShape(Capsule())
                            }
                        }
                        // знакомство телефонов для контактов, добавленных
                        // не при встрече: только в открытом чате и только
                        // когда собеседник рядом (07.08)
                        if offerPairing, let contact = model.contact {
                            NearbyPairingOfferBar(
                                contactName: contact.name,
                                onAccept: { startPairing(with: contact) },
                                onDecline: {
                                    NearbyPresence.shared.markDeclined(
                                        contactID: contact.id)
                                    offerPairing = false
                                })
                        }
                        if let line = pairingFailure {
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundStyle(RMDesign.warning)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                        }
                        if model.suggesting { suggestionBar }
                        composer
                    }
                    .background(RMDesign.background)
                    .overlay(alignment: .top) {
                        // тонкий разделитель — отделение от ленты (токены:
                        // inset-линия rgba(233,233,237,.1), мокап composer)
                        Rectangle()
                            .fill(RMDesign.textPrimary.opacity(0.10))
                            .frame(height: 1)
                    }
                }
                .background(RMDesign.background)
                .navigationTitle(model.contact?.name ?? "Собеседник (демо)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Состояние сверки видно В ЧАТЕ (WP1): нажатие —
                    // экран сверки; статус читается из хранилища, не из
                    // снимка (мог смениться, пока чат открыт)
                    if let contact = model.contact {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                verifyContact = ContactStore.load()
                                    .first { $0.id == contact.id } ?? contact
                            } label: {
                                trustSeal(for: contact.id)
                            }
                            .accessibilityLabel("Сверка ключа")
                        }
                    }
                    // Шеринг позиции (WP4): выключен по умолчанию, грант
                    // адресный с TTL, индикатор виден, пока активен.
                    // Спрятан за FeatureFlags.geoInChat (вердикт 19.08)
                    if FeatureFlags.geoInChat, let contact = model.contact {
                        ToolbarItem(placement: .topBarTrailing) {
                            LocationShareMenu(contactID: contact.id)
                        }
                    }
                }
                .sheet(item: $verifyContact) { fresh in
                    ContactVerifySheet(contact: fresh) {
                        ContactStore.markVerified(id: fresh.id)
                        verifyContact = nil
                        trustTick += 1     // перерисовать печать
                    } onCancel: {
                        verifyContact = nil
                    }
                    .presentationDetents([.large])
                }
                .onAppear { model.reload() }
                .onReceive(DeliveryManager.shared.$eventCounter) { _ in
                    model.reload()   // входящие/ack — лента перечитывается
                }
                .onReceive(DeliveryManager.shared.$linkWarning) {
                    linkWarning = $0
                }
                // Баннер знакомства не смеет прерывать набор и диктовку
                // (условие владельца 08.08) — центр придержит его
    }


    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: SophieDesign.messageSpacing) {
                    if model.entries.isEmpty {
                        Text(Self.emptyFeedHint(isDemo: model.contact == nil))
                            .font(SophieDesign.captionFont)
                            .foregroundStyle(RMDesign.textTertiary)
                            .padding(.top, 24)
                            .padding(.horizontal, 20)
                    }
                    ForEach(model.entries) { entry in
                        row(entry).id(entry.id)
                    }
                    // якорь низа: scrollTo по id строки в LazyVStack
                    // промахивается, пока строка не разложена — маркер
                    // всегда в иерархии, к нему прокрутка надёжна
                    Color.clear.frame(height: 1).id("feed-bottom")
                }
                .padding(.horizontal, SophieDesign.screenPadding)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            // блок 6 (полевое 09.08): клавиатуру нельзя было убрать,
            // не выходя из чата. Свайп вниз по ленте прячет её
            // интерактивно, тап по ленте — сразу; тапы пузырей
            // (зеркало получателя) перехватываются их жестами раньше
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { inputFocused = false }
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: model.entries.count) { scrollToBottom(proxy) }
            .onChange(of: model.entries.last?.text) { scrollToBottom(proxy) }
            // Б1-repro (29.07, дорога): смена высоты композера (старт/стоп
            // рекордера, плашка одобрения) прыгает contentOffset —
            // лента визуально «пустеет» до ручной протяжки. Докрутка
            // к якорю на каждом таком переходе возвращает контент.
            .onChange(of: model.dictationState) {
                scrollToBottom(proxy, afterMilliseconds: 250)
            }
            .onChange(of: model.approval != nil) {
                scrollToBottom(proxy, afterMilliseconds: 250)
            }
            // Поворот телефона и возврат в вертикаль (замечание владельца
            // 02.08: «уехал чат»): после смены геометрии contentOffset
            // остаётся от старого размера — докручиваем к якорю низа.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                scrollToBottom(proxy, afterMilliseconds: 120)
            }
            .onChange(of: model.isRecalculating) {
                scrollToBottom(proxy, afterMilliseconds: 250)
            }
            .onChange(of: inputFocused) {
                // клавиатура открылась — подскроллить к последнему
                // (после анимации inset, иначе геометрия ещё старая)
                guard inputFocused else { return }
                scrollToBottom(proxy, afterMilliseconds: 300)
            }
        }
    }

    /// Прокрутка к низу ленты — отложенно, чтобы LazyVStack успел
    /// разложить свежие строки (иначе scrollTo промахивается и новое
    /// сообщение остаётся спрятанным за композером).
    private func scrollToBottom(_ proxy: ScrollViewProxy,
                                afterMilliseconds delay: Int = 80) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            withAnimation { proxy.scrollTo("feed-bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func row(_ entry: ChatEntry) -> some View {
        switch entry.kind {
        case .outgoing: outgoingBubble(entry)
        case .incoming: incomingBubble(entry)
        case .whisperQuestion: whisperCard(entry, isAnswer: false)
        case .whisperAnswer: whisperCard(entry, isAnswer: true)
        }
    }

    /// Своё сообщение человеку: нейтральный акцент приложения (не синий!).
    /// Под пузырём — время created (или «записано · отправлено», если
    /// лежало в очереди); статусная строка получает «доставлено HH:MM»
    /// с подтверждением получателя.
    private func outgoingBubble(_ entry: ChatEntry) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            // Пузырь разворачивается на языке тумблера RU/EN (Dev):
            // семантические — по кодам, текстовые — как есть
            Text(entry.displayText(language: model.unfoldLanguage))
                .font(SophieDesign.messageFont)
                .lineSpacing(15 * 0.45)
                .foregroundStyle(Color(hex: 0xf5f4ff))
                .padding(.horizontal, SophieDesign.bubblePaddingH)
                .padding(.vertical, SophieDesign.bubblePaddingV)
                .background(entry.isSOSRelated
                            ? RMDesign.danger.opacity(0.18)
                            : RMDesign.accentSurface)
                .clipShape(BubbleShape(ownSide: true))
                .overlay {
                    if entry.isSOSRelated {
                        BubbleShape(ownSide: true)
                            .stroke(RMDesign.danger.opacity(0.7),
                                    lineWidth: 1)
                    }
                }
                .onTapGesture {
                    // тап по семантическому пузырю — зеркало получателя
                    guard entry.semanticBlob != nil else { return }
                    if mirrorShown.contains(entry.id) {
                        mirrorShown.remove(entry.id)
                    } else {
                        mirrorShown.insert(entry.id)
                    }
                }
            if mirrorShown.contains(entry.id),
               let mirror = entry.receiverMirror() {
                (Text("получатель увидит: ")
                    .foregroundStyle(RMDesign.textTertiary)
                 + Text(mirror)
                    .foregroundStyle(RMDesign.textSecondary))
                    .font(.system(size: 12.5))
                    .italic()
                    .padding(.horizontal, SophieDesign.bubblePaddingH)
                    .padding(.vertical, 6)
                    .background(RMDesign.surface1)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            // Две отметки (замечание владельца 02.08): отправлено /
            // доставлено. Цвет = состояние: жёлтое ждёт, серое сбылось,
            // зелёное — прочитано получателем.
            HStack(spacing: 4) {
                if let status = entry.status, entry.deliveredAt == nil,
                   entry.sentAt == nil {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(RMDesign.warning)
                }
                // как ушло — одним словом, факт, не выбор (бриф 07.08)
                if let word = ChatEntry.pathWord(entry.sentVia),
                   entry.sentAt != nil {
                    Text(word)
                        .font(.system(size: 11))
                        .foregroundStyle(RMDesign.textTertiary)
                    Text("·").font(.system(size: 11))
                        .foregroundStyle(RMDesign.textTertiary)
                }
                Text(entry.stampSent)
                    .font(.system(size: 11))
                    .foregroundStyle(entry.stampState == .queued
                                     ? RMDesign.warning       // ещё не ушло
                                     : RMDesign.textTertiary) // ушло
                if let delivered = entry.stampDelivered {
                    Text("/").font(.system(size: 11))
                        .foregroundStyle(RMDesign.textTertiary)
                    Text(delivered)
                        .font(.system(size: 11))
                        .foregroundStyle(entry.stampState == .read
                                         ? RMDesign.success   // прочитано
                                         : RMDesign.warning)  // доставлено
                }
            }
            // честная недоставка словами (мега-3, 14.08): ушло, но
            // подтверждения нет дольше минуты — не молчим жёлтой меткой
            if let hint = entry.undeliveredHint() {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(RMDesign.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }

    /// Принятое сообщение: пузырь слева, поверхность 2 (токены).
    /// Связанное с SOS (ответ на мой сигнал, чужой сигнал) — красным:
    /// красный зарезервирован только под SOS и тревогу.
    private func incomingBubble(_ entry: ChatEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.displayText(language: model.unfoldLanguage))
                .font(SophieDesign.messageFont)
                .lineSpacing(15 * 0.45)
                .foregroundStyle(RMDesign.textPrimary)
                .padding(.horizontal, SophieDesign.bubblePaddingH)
                .padding(.vertical, SophieDesign.bubblePaddingV)
                .background(entry.isSOSRelated
                            ? RMDesign.danger.opacity(0.18)
                            : RMDesign.surface2)
                .clipShape(BubbleShape(ownSide: false))
                .overlay {
                    if entry.isSOSRelated {
                        BubbleShape(ownSide: false)
                            .stroke(RMDesign.danger.opacity(0.7),
                                    lineWidth: 1)
                    }
                }
                .onTapGesture {
                    // Пометка развёртки (решение владельца 06.08,
                    // вариант 2): семантическое сообщение — не дословная
                    // цитата; тап раскрывает «развёрнуто словарём» +
                    // рендер другой колонки. На пузыре пометка не шумит.
                    guard entry.semanticBlob != nil else { return }
                    if mirrorShown.contains(entry.id) {
                        mirrorShown.remove(entry.id)
                    } else {
                        mirrorShown.insert(entry.id)
                    }
                }
            if mirrorShown.contains(entry.id), entry.semanticBlob != nil {
                let other = model.unfoldLanguage == "ru" ? "en" : "ru"
                (Text("развёрнуто словарём · ")
                    .foregroundStyle(RMDesign.textTertiary)
                 + Text(entry.receiverMirror(language: other)
                        ?? "рендер недоступен")
                    .foregroundStyle(RMDesign.textSecondary))
                    .font(.system(size: 12.5))
                    .italic()
                    .padding(.horizontal, SophieDesign.bubblePaddingH)
                    .padding(.vertical, 6)
                    .background(RMDesign.surface1)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text(entry.incomingTimeLine)
                .font(.system(size: 11))
                .foregroundStyle(RMDesign.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
    }

    /// Карточка шёпота: радиус 12 (сознательно не пузырь), sophie-card,
    /// синяя обводка, ярлык «ТОЛЬКО ВЫ ВИДИТЕ».
    private func whisperCard(_ entry: ChatEntry, isAnswer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10))
                Text("ТОЛЬКО ВЫ ВИДИТЕ")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.22)
            }
            .foregroundStyle(SophieDesign.sophie)

            Text(entry.text.isEmpty ? "…" : entry.text)
                .font(.system(size: 14.5))
                .lineSpacing(14.5 * 0.5)
                .foregroundStyle(isAnswer ? SophieDesign.sophieTextStrong
                                          : SophieDesign.sophieText)
                .textSelection(.enabled)

            if entry.isStopped {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SophieDesign.sophieLight.opacity(0.75))
                        .frame(width: 9, height: 9)
                    Text("ОСТАНОВЛЕНО ВАМИ · ОТВЕТ НЕПОЛНЫЙ")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SophieDesign.sophieLight.opacity(0.75))
                }
            }

            if isAnswer && !entry.text.isEmpty {
                // Действия — иконками (мокап whisper_cards; принцип:
                // в ленте — иконки, модальные подтверждения — словами).
                // «В черновик» — единственный путь шёпота в сообщение (§3.3)
                HStack(spacing: 4) {
                    Spacer()
                    whisperAction("square.and.pencil", "В черновик") {
                        model.insertDraft(entry.text)
                    }
                    whisperAction("doc.on.doc", "Копировать") {
                        UIPasteboard.general.string = entry.text
                    }
                    whisperAction("eye.slash", "Скрыть") {
                        model.hideWhisper(entry.id)
                    }
                }
            }
        }
        .padding(13)
        .background(Color(hex: 0x132436))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(SophieDesign.sophie.opacity(isAnswer ? 0.55 : 0.40),
                          lineWidth: 1))
        .frame(maxWidth: .infinity,
               alignment: isAnswer ? .leading : .trailing)
        .padding(isAnswer ? .trailing : .leading, 40)
    }

    /// Иконка-действие карточки шёпота: вид 34pt по мокапу, хит-зона 44pt,
    /// long-press показывает подпись (контекстное меню с тем же действием).
    private func whisperAction(_ symbol: String, _ label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(SophieDesign.sophieText.opacity(0.62))
                .frame(width: 34, height: 34)
                .frame(width: 44, height: 44)     // хит-зона 44pt
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .contextMenu {
            Button(label, systemImage: symbol, action: action)
        }
    }

    /// Плашка автодополнения: поле ещё НЕ синее (цвет — только с чипом).
    private var suggestionBar: some View {
        Button {
            model.acceptSuggestion()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .foregroundStyle(SophieDesign.sophieLight)
                Text("@\(AppIdentity.assistantName) · спросить локально")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(SophieDesign.sophieText)
                Spacer()
                Text("видно только вам")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RMDesign.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color(hex: 0x132436))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    /// Бейдж одобрения над полем (semantic_compression §4): человек видит
    /// режим и цену отправки; тап — переключатель «смыслами/текстом».
    @ViewBuilder
    private var approvalBadge: some View {
        if model.dictationState == .processing {
            // спиннер уже в полосе «обрабатываю…» — бейдж не дублируем
            EmptyView()
        } else if model.isEncoding || model.isRecalculating {
            ApprovalBadgeView(state: .recalculating)
        } else if let a = model.approval {
            ApprovalBadgeView(
                state: a.mode == .semantic && a.semantic != nil
                    ? .semantic(bytes: a.semantic!.blob.count,
                                loopChecked: a.semantic!.loopRewritten != nil)
                    : .text(packets: a.textPackets, reason: a.reason),
                onTap: { model.toggleApprovalMode() })
        }
    }

    /// «1 пакет», «2 пакета», «5 пакетов» — падеж считает код, не модель.
    static func packetWord(_ n: Int) -> String {
        let last2 = n % 100, last = n % 10
        if (11...14).contains(last2) { return "пакетов" }
        switch last {
        case 1: return "пакет"
        case 2, 3, 4: return "пакета"
        default: return "пакетов"
        }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            approvalBadge
            HStack(spacing: 8) {
                switch model.dictationState {
                case .recording where model.dictation.isRecognizing:
                    // фаза 1 после ■: файл ушёл в распознаватель
                    DictationProcessingBar(label: "распознаю…")
                case .recording:
                    // Запись: × — волна+таймер — ■ на месте mic;
                    // кнопка отправки скрыта, текста НЕТ ни в каком виде
                    DictationRecordingBar(
                        levels: model.dictation.levels,
                        elapsed: model.dictation.elapsed,
                        accent: model.whisperMode ? SophieDesign.sophie
                                                  : RMDesign.accentLight,
                        onCancel: { model.cancelDictation() },
                        onStop: { model.dictation.stopAndDeliver() })
                case .processing:
                    // фаза 2: текст пошёл в семантический конвейер
                    DictationProcessingBar()
                case .idle:
                    inputField
                    sendButton
                }
            }
            // Выигрыш — ТОЛЬКО в пакетах и только когда их стало меньше
            // (решение владельца 08.08: экономия байтов внутри одного
            // пакета человеку ничего не даёт и читается как шум).
            if let win = model.optimizerWin {
                Text("короче: \(win.before) → \(win.after) "
                     + Self.packetWord(win.after))
                    .font(.system(size: 11.5))
                    .foregroundStyle(RMDesign.accentLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            // Нерабочий исход сокращения — честной строкой, не молчанием
            // («тишина не есть отказ»: молчание кнопки читается как
            // поломка, полевые прогоны 08.08 и 19.08)
            if let rejection = model.optimizerRejection {
                Text(rejection)
                    .font(.system(size: 11.5))
                    .foregroundStyle(RMDesign.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            if model.whisperMode {
                Text("Виден только вам · в эфир не уходит")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SophieDesign.sophie.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            if let hint = model.dictationHint {
                HStack(spacing: 8) {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(RMDesign.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.dictation.permissionDenied {
                        // одним нажатием в Настройки, а не «пойдите сами»
                        Button("Открыть Настройки") {
                            if let url = URL(
                                string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(RMDesign.accentLight)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear { model.dictation.checkSupport() }
    }

    private var inputField: some View {
        HStack(spacing: 7) {
            if model.whisperMode {
                // Чип @Софи с ✕ — второй сигнал режима, помимо цвета
                HStack(spacing: 5) {
                    Text("@\(AppIdentity.assistantName)")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(SophieDesign.sophieLight)
                    Button {
                        model.dismissChip()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SophieDesign.sophieLight.opacity(0.7))
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(SophieDesign.sophieSurface)
                .clipShape(Capsule())
            }
            TextField(model.whisperMode ? "Спросить \(AppIdentity.assistantName)…" : "Сообщение…",
                      text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .font(SophieDesign.messageFont)
                .foregroundStyle(RMDesign.textPrimary)
                .onChange(of: model.draft) { old, new in
                    model.draftEdited(old: old, new: new)
                }
                .onSubmit { model.send() }

            // Микрофон внутри поля (мокап composer_normal);
            // on-device ru недоступен — приглушён, тап даёт подсказку.
            // Есть что сократить — микрофон уступает место оптимизации
            // (часть 2 брифа 08.08): одна кнопка, режим следует за тем,
            // что сейчас полезно человеку.
            if model.isOptimizing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 40, height: 40)
            } else if model.optimizerOffered {
                Button {
                    model.optimizerTapped()
                } label: {
                    Image(systemName: model.optimizerShowingShort
                          ? "arrow.uturn.backward" : "text.append")
                        .font(.system(size: 17))
                        .foregroundStyle(RMDesign.accentLight)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(model.optimizerShowingShort
                                    ? "Вернуть как сказал" : "Сделать короче")
            } else {
                Button {
                    model.micTapped()
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 17))
                        .foregroundStyle(model.dictation.unavailableHint == nil
                                         ? RMDesign.textSecondary
                                         : RMDesign.textPrimary.opacity(0.25))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Диктовка")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: SophieDesign.controlSize)
        .background(model.whisperMode ? Color(hex: 0x132436)
                                      : RMDesign.surface1)
        .clipShape(RoundedRectangle(cornerRadius: SophieDesign.fieldRadius))
        .overlay {
            if model.whisperMode {
                RoundedRectangle(cornerRadius: SophieDesign.fieldRadius)
                    .strokeBorder(SophieDesign.sophie, lineWidth: 1.2)
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isEncoding {
            ProgressView()
                .frame(width: SophieDesign.controlSize,
                       height: SophieDesign.controlSize)
                .background(RMDesign.surface1)
                .clipShape(Circle())
        } else if model.isWhisperGenerating {
            Button { model.stopWhisper() } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(SophieDesign.sophieLight)
                    .frame(width: SophieDesign.controlSize,
                           height: SophieDesign.controlSize)
                    .background(SophieDesign.sophieSurface)
                    .clipShape(Circle())
            }
        } else {
            // Иконка меняется вместе с режимом: стрелка → искра (шёпот);
            // готовое одобрение — галочка «подтвердить» (второй тап шлёт)
            Button { model.send() } label: {
                Image(systemName: model.whisperMode ? "sparkle"
                      : model.approval != nil ? "checkmark" : "arrow.up")
                    .fontWeight(.semibold)
                    .foregroundStyle(model.whisperMode ? SophieDesign.sophieLight
                                                       : RMDesign.accentLight)
                    .frame(width: SophieDesign.controlSize,
                           height: SophieDesign.controlSize)
                    .background(model.whisperMode ? SophieDesign.sophieSurface
                                                  : RMDesign.accentSurface)
                    .clipShape(Circle())
            }
            .disabled(model.draft.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
                || (model.whisperMode && !model.gateOpen))
        }
    }
}

#Preview {
    HumanChatView()
}

// MARK: - Бейдж одобрения (канон)
// Одобрение инлайн в композере: реализация первична, источник —
// semantic_compression.md §4. Канонизировано скриншотом
// design/sophie/screens/send_confirmation.png (тест
// canonizeSendConfirmationScreenshot); изменения вида — только через
// обновление скриншота тем же тестом.

struct ApprovalBadgeView: View {
    enum BadgeState {
        case recalculating
        /// loopChecked — прошла смысловая петля: в поле сверенный Софи
        /// русский, а не машинная развёртка, поэтому формулировка другая.
        case semantic(bytes: Int, loopChecked: Bool = false)
        case text(packets: Int, reason: String?)
    }
    let state: BadgeState
    var onTap: (() -> Void)?

    var body: some View {
        Group {
            switch state {
            case .recalculating:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("пересчитываю…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RMDesign.textSecondary)
                    Spacer(minLength: 0)
                }
            case .semantic(let bytes, let loopChecked):
                badgeButton {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text((loopChecked ? "смысл сверен" : "так увидит получатель")
                             + " · \(bytes) Б · 1 пакет")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(RMDesign.success)
                }
            case .text(let packets, let reason):
                badgeButton {
                    HStack(spacing: 6) {
                        Text("текстом · \(packets) "
                           + "пакет\(packets == 1 ? "" : packets < 5 ? "а" : "ов")"
                           + (reason.map { " · \($0)" } ?? ""))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(RMDesign.warning)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func badgeButton(@ViewBuilder _ label: () -> some View) -> some View {
        if let onTap {
            Button(action: onTap) { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            label()
        }
    }
}

/// Канон-вью потока одобрения для скриншота: бейдж + поле с развёрнутым
/// текстом получателя + галочка подтверждения (второй тап шлёт).
struct SendApprovalCanon: View {
    var body: some View {
        VStack(spacing: 4) {
            ApprovalBadgeView(state: .semantic(bytes: 78), onTap: {})
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Text("Там в 20 минут ждать у пирса")
                        .font(SophieDesign.messageFont)
                        .foregroundStyle(RMDesign.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "mic")
                        .font(.system(size: 17))
                        .foregroundStyle(RMDesign.textSecondary)
                        .frame(width: 40, height: 40)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: SophieDesign.controlSize)
                .background(RMDesign.surface1)
                .clipShape(RoundedRectangle(cornerRadius: SophieDesign.fieldRadius))

                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(RMDesign.accentLight)
                    .frame(width: SophieDesign.controlSize,
                           height: SophieDesign.controlSize)
                    .background(RMDesign.accentSurface)
                    .clipShape(Circle())
            }
            ApprovalBadgeView(state: .text(packets: 2,
                                           reason: "в тексте слишком много цифр"))
            ApprovalBadgeView(state: .recalculating)
        }
        .padding(12)
        .background(RMDesign.background)
        .preferredColorScheme(.dark)
    }
}
