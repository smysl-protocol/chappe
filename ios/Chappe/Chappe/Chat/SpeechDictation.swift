import Foundation
import Combine
import Speech
import AVFoundation

// ============================================================================
// Диктовка — архитектура «файл + одно распознавание»:
//
//   recording:  AVAudioRecorder пишет .m4a во временный файл; волна —
//               из metering рекордера, таймер идёт. SFSpeechRecognizer
//               во время записи НЕ работает вообще — никаких сессий,
//               рестартов и партиалов: паузам нечего терять.
//   ■ (стоп):   запись остановлена → SFSpeechURLRecognitionRequest на
//               файл (СТРОГО on-device, ноль байт наружу), ждём финал
//               одним запросом → onFinished(текст). Файл удаляется
//               сразу после распознавания — аудио не храним.
//   × (отмена): стоп, файл в мусор.
//
// Длинные записи: сначала целиком; не распозналось и длиннее ~35 с —
// файл режется на куски по 30 с (ровно) и распознаётся последовательно.
// ============================================================================

/// Debug-лог последней диктовки (виден в Dev): длительность файла,
/// путь распознавания, границы и длины чанков, итог склейки.
nonisolated struct DictationDebugLog: Codable {
    struct Chunk: Codable {
        var start: Double
        var end: Double
        var textLength: Int      // длина распознанного текста куска
        var retried: Bool = false
        var failed: Bool = false
    }
    /// Полный таймстемп стадии: запись start/stop, распознавание,
    /// пивот-чанки, петля, кодирование — ответ на «когда» навсегда.
    struct Stage: Codable {
        var name: String
        var at: Date
    }
    var date = Date()
    var fileDuration: Double = 0
    var path = ""                // «целиком» / «целиком (частично) → чанки» …
    var wholeCoverage: Double?   // покрытие финала целого файла (0…1)
    var chunks: [Chunk] = []
    var joinedLength = 0         // длина итоговой склейки
    var stages: [Stage] = []

    static func url() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("dictation_debug.json")
    }

    static func load() -> DictationDebugLog? {
        guard let url = try? url(), let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DictationDebugLog.self, from: data)
    }

    func save() {
        guard let url = try? Self.url() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Дописать стадию в сохранённый лог (стадии конвейера после
    /// распознавания: пивот-чанки, петля, кодирование).
    static func stage(_ name: String) {
        var log = load() ?? DictationDebugLog()
        log.stages.append(Stage(name: name, at: Date()))
        log.save()
    }
}

@MainActor
final class SpeechDictation: ObservableObject {
    /// Сегменты последнего распознавания по паузам STT (вклады чанков
    /// склейки) — сегментатор источника для смешанного режима.
    private(set) var lastPauseSegments: [String] = []

    /// Тумблер Dev «хранить последнюю запись для отладки»: файл
    /// переезжает в tmp/last_dictation.m4a вместо удаления.
    nonisolated static var keepLastRecording: Bool {
        get { UserDefaults.standard.bool(forKey: "dictation_keep_last_recording") }
        set { UserDefaults.standard.set(newValue, forKey: "dictation_keep_last_recording") }
    }

    /// Куда уезжает последняя запись при включённом тумблере.
    nonisolated static var lastRecordingURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("last_dictation.m4a")
    }

    enum Availability {
        case available
        case denied(String)        // нет разрешений
        case unsupported(String)   // on-device ru-RU недоступен
        case unknown               // ещё не спрашивали
    }

    @Published var isRecording = false
    /// Фаза «распознаю…» после ■ (файл ушёл в распознаватель).
    @Published private(set) var isRecognizing = false
    @Published private(set) var availability: Availability = .unknown

    /// Живая волна амплитуды для индикатора записи: barCount уровней 0…1.
    @Published private(set) var levels: [Float] =
        Array(repeating: 0, count: SpeechDictation.barCount)
    /// Секунды с начала записи (таймер индикатора).
    @Published private(set) var elapsed: TimeInterval = 0

    static let barCount = 24

    /// Причина пустого результата (для подсказки владельца).
    private(set) var recognitionFailure: String?
    /// Последняя ошибка распознавателя дословно (debug/бенч).
    private(set) var lastRecognitionError: String?

    /// id записи корпуса последней диктовки — конвейер дозаполняет.
    static var lastCorpusID: String?

    /// Готовый текст по ■ (после распознавания файла): владелец решает,
    /// что с ним делать (конвейер в демо-чате, поле ввода у Софи/шёпота).
    var onFinished: (@MainActor (String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var timer: Timer?
    private var startedAt: Date?
    /// Таймлайн уровней записи (тик 0.1 с) — для выбора тихих точек реза.
    private var meterTimeline: [(t: Double, level: Float)] = []
    /// Живые делегаты распознавания файлов (удержание до конца таска).
    private var activeDelegates = Set<FileRecognitionDelegate>()
    /// Стадии текущей сессии диктовки (запись start/stop) — уходят
    /// в debug-лог при распознавании.
    private var sessionStages: [DictationDebugLog.Stage] = []

    /// Подсказка для неактивной кнопки (nil — кнопка активна).
    var unavailableHint: String? {
        switch availability {
        case .available, .unknown: nil
        case .denied(let hint), .unsupported(let hint): hint
        }
    }

    /// Разрешение отклонено — UI показывает однотапную дверь в Настройки.
    var permissionDenied: Bool {
        if case .denied = availability { return true }
        return false
    }

    /// Последовательность запросов разрешений — чистая, под замок.
    /// ОБА запроса выполняются всегда, даже после отказа в первом:
    /// строка разрешения в Настройках телефона рождается только самим
    /// запросом — оборванная цепочка оставляла человека перед
    /// «включите в Настройках», где включать нечего (полевой прогон
    /// 09.08, второй телефон).
    nonisolated static func requestPermissions(
        requestSpeech: () async -> SFSpeechRecognizerAuthorizationStatus,
        requestMic: () async -> Bool
    ) async -> (speechOK: Bool, micOK: Bool) {
        let speech = await requestSpeech()
        let mic = await requestMic()
        return (speech == .authorized, mic)
    }

    enum PreflightOutcome: Equatable {
        case ready, speechDenied, micDenied, unsupported
    }

    /// Порядок гейтов старта — под замок (полевой тупик тел 2, 10.08):
    /// разрешения запрашиваются ВСЕГДА И ПЕРВЫМИ, support-гейт — после.
    /// Причины две: строка разрешения в Настройках телефона рождается
    /// только самим запросом, а supportsOnDeviceRecognition умеет врать
    /// false до выдачи авторизации — support-гейт первым замыкал
    /// спираль: запрос не фаерится → support не оживёт → запрос не
    /// фаерится, и в Настройках включать нечего.
    nonisolated static func preflight(
        requestSpeech: () async -> SFSpeechRecognizerAuthorizationStatus,
        requestMic: () async -> Bool,
        checkSupport: @MainActor () -> Bool
    ) async -> PreflightOutcome {
        let outcome = await requestPermissions(
            requestSpeech: requestSpeech, requestMic: requestMic)
        guard outcome.speechOK else { return .speechDenied }
        guard outcome.micOK else { return .micDenied }
        return await checkSupport() ? .ready : .unsupported
    }

    /// Читаемое имя статуса speech — для дневника-зонда.
    nonisolated static func speechStatusName(
        _ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined — диалог не показан"
        case .denied: "denied — пользователь отклонил"
        case .restricted: "restricted — ЗАПРЕТ СИСТЕМЫ (Screen Time/профиль)"
        case .authorized: "authorized — разрешено"
        @unknown default: "неизвестно"
        }
    }

    /// Точная подсказка при отказе речи (полевой тупик тел 2, сборка
    /// 11): .restricted — запрет СИСТЕМЫ (Siri и Диктовка клавиатуры
    /// выключены обе, либо Screen Time) — запрос возвращается БЕЗ
    /// диалога, строка Speech Recognition в настройках приложения не
    /// рождается, и дверь «включите в Настройках приложения» ведёт в
    /// пустоту. Человека надо вести к системным тумблерам.
    nonisolated static func speechDenialHint(
        _ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        status == .restricted
            ? "Распознавание речи запрещено системой — включите "
            + "Диктовку (Настройки → Основные → Клавиатура) или Siri"
            : "Нет разрешения на распознавание речи"
    }

    /// Проверка возможности диктовки БЕЗ запроса разрешений (для UI).
    func checkSupport() {
        guard let recognizer else {
            availability = .unsupported("Распознавание русского недоступно "
                                      + "на этом устройстве")
            return
        }
        if !recognizer.supportsOnDeviceRecognition {
            // Чаще всего лечится скачиванием языка: русская клавиатура
            // с включённой Диктовкой тянет on-device пакет
            availability = .unsupported("Русский для распознавания на "
                                      + "устройстве не скачан — добавьте "
                                      + "русскую клавиатуру и включите "
                                      + "Диктовку (Настройки → Основные → "
                                      + "Клавиатура). В облако ничего не "
                                      + "отправляем")
            return
        }
        if case .denied = availability {
            // Отказ пересматривается по ФАКТУ (полевой прогон 08.08:
            // человек включил разрешение в Настройках телефона, а строка
            // отказа прилипла навсегда — ранний return не давал ей
            // сброситься; сама проверка разрешений не запрашивает)
            let speech = SFSpeechRecognizer.authorizationStatus()
            let speechOK = speech != .denied && speech != .restricted
            let micOK = AVAudioApplication.shared.recordPermission != .denied
            if speechOK && micOK { availability = .available }
            return
        }
        availability = .available
    }

    // MARK: Запись

    /// Старт записи в файл. false — не началась (нет поддержки или
    /// разрешений), подсказка в unavailableHint.
    /// Разрешения — ПЕРВЫМИ, support-гейт после (см. preflight).
    func start() async -> Bool {
        guard !isRecording, !isRecognizing else { return true }
        switch await Self.preflight(
            requestSpeech: {
                await withCheckedContinuation { c in
                    SFSpeechRecognizer.requestAuthorization {
                        c.resume(returning: $0)
                    }
                }
            },
            requestMic: { await AVAudioApplication.requestRecordPermission() },
            checkSupport: { [self] in
                checkSupport()
                if case .available = availability { return true }
                return false
            }) {
        case .speechDenied:
            availability = .denied(Self.speechDenialHint(
                SFSpeechRecognizer.authorizationStatus()))
            return false
        case .micDenied:
            availability = .denied("Нет доступа к микрофону")
            return false
        case .unsupported:
            return false   // подсказка уже легла в availability
        case .ready:
            break
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement,
                                    options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictation_\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw NSError(domain: "chappe.dictation", code: 1)
            }
            self.recorder = recorder
            self.fileURL = url
            recognitionFailure = nil
            sessionStages = [.init(name: "запись start", at: Date())]
            meterTimeline = []
            levels = Array(repeating: 0, count: Self.barCount)
            elapsed = 0
            startedAt = Date()
            isRecording = true
            // один таймер: волна из metering + секунды
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            return true
        } catch {
            cleanupRecording()
            availability = .unsupported("Микрофон не запустился: "
                                      + error.localizedDescription)
            return false
        }
    }

    private func tick() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        // дБ (-160…0) → линейная амплитуда; множитель — под речь
        let db = recorder.averagePower(forChannel: 0)
        let level = min(1, pow(10, db / 20) * 9)
        levels.removeFirst()
        levels.append(level)
        meterTimeline.append((recorder.currentTime, level))
        if let startedAt {
            elapsed = Date().timeIntervalSince(startedAt)
        }
    }

    /// ■ — стоп записи → «распознаю…» → текст владельцу, файл в мусор
    /// (или в tmp/last_dictation.m4a при включённом Dev-тумблере).
    func stopAndDeliver() {
        guard isRecording, let url = fileURL else { return }
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        sessionStages.append(.init(name: "запись stop", at: Date()))
        cleanupRecording(deleteFile: false)
        isRecognizing = true
        Task {
            let text = await recognizeFile(url: url, duration: duration)
            // Авто-корпус (п.3, 31.07): каждая диктовка — фикстура
            // (аудио+транскрипт сейчас, конвейерные поля дополнит
            // HumanChatModel по lastCorpusID). Пока файл жив.
            if let text, !text.isEmpty {
                Self.lastCorpusID = DictationCorpus.begin(transcript: text,
                                                          audioURL: url)
            }
            if Self.keepLastRecording {
                try? FileManager.default.removeItem(at: Self.lastRecordingURL)
                try? FileManager.default.moveItem(at: url,
                                                  to: Self.lastRecordingURL)
            } else {
                try? FileManager.default.removeItem(at: url)   // аудио не храним
            }
            fileURL = nil
            isRecognizing = false
            onFinished?(text ?? "")
        }
    }

    /// × — отмена: стоп, файл удалить, ничего не распознаём.
    func cancel() {
        recorder?.stop()
        cleanupRecording()
    }

    private func cleanupRecording(deleteFile: Bool = true) {
        recorder = nil
        timer?.invalidate()
        timer = nil
        startedAt = nil
        isRecording = false
        levels = Array(repeating: 0, count: Self.barCount)
        elapsed = 0
        if deleteFile {
            meterTimeline = []
            if let url = fileURL {
                try? FileManager.default.removeItem(at: url)
                fileURL = nil
            }
        }
    }

    // MARK: Распознавание файла (по стопу, одним запросом)

    /// Сначала весь файл целиком; частичное покрытие финала (<85%) или
    /// отказ → нарезка на чанки по тихим точкам с перекрытием 1 с.
    /// Каждый заход пишет debug-лог (Dev → Диктовка · отладка).
    /// Internal — авто-бенч гоняет готовый файл этим же путём.
    func recognizeFile(url: URL, duration: TimeInterval) async -> String? {
        var log = DictationDebugLog(fileDuration: duration)
        log.stages = sessionStages   // запись start/stop, если была
        sessionStages = []
        log.stages.append(.init(name: "распознавание start", at: Date()))
        defer {
            log.stages.append(.init(name: "распознавание конец", at: Date()))
            log.save()
        }

        // 1. Весь файл одним запросом
        if let whole = await recognize(url: url) {
            let coverage = Self.coverageRatio(
                segments: [(0, whole.lastSegmentEnd)], duration: duration)
            log.wholeCoverage = coverage
            // Ловушка частичного успеха: финал есть, но покрывает не всё
            // (on-device лимит одного прохода ≈ 60 с) — раньше порог 0.85
            // МОЛЧА резал до 15% хвоста (баг 29.07: «оборвалось на
            // Испании»). Теперь хвост дораспознаётся отдельным куском.
            if coverage >= 0.85 {
                var text = whole.text
                if duration - whole.lastSegmentEnd > 3,
                   let tailPiece = await exportChunk(
                        of: url,
                        range: (max(0, whole.lastSegmentEnd - 1),
                                duration - max(0, whole.lastSegmentEnd - 1))) {
                    let tail = await recognize(url: tailPiece)?.text
                    try? FileManager.default.removeItem(at: tailPiece)
                    if let tail, !tail.isEmpty {
                        log.path = "целиком + хвост"
                        text = Self.dedupJoinPair(text, tail)
                    } else {
                        log.path = "целиком, хвост не распознался"
                        text += " […]"      // честный маркер, не молчание
                    }
                } else {
                    log.path = "целиком"
                }
                log.joinedLength = text.count
                return text
            }
            log.path = String(format: "целиком частично (%.0f%%) → чанки",
                              coverage * 100)
        } else if duration > 35 {
            log.path = "целиком не вышло → чанки"
        } else {
            log.path = "целиком не вышло (короткий файл)"
            recognitionFailure = "Распознавание не справилось — попробуйте ещё раз"
            return nil
        }

        // 2. Чанки: границы в тихих окнах ±3 с от цели, перекрытие 1 с.
        //    Результаты — строго append по порядку; отказ чанка → один
        //    повтор → маркер […]. Ничего не отбрасываем молча.
        let ranges = Self.chunkRanges(duration: duration,
                                      timeline: meterTimeline)
        var parts: [(ok: Bool, text: String)] = []
        for range in ranges {
            var chunkLog = DictationDebugLog.Chunk(
                start: range.start, end: range.start + range.duration,
                textLength: 0)
            var text: String?
            if let piece = await exportChunk(of: url, range: range) {
                text = await recognize(url: piece)?.text
                if text == nil || text!.isEmpty {
                    chunkLog.retried = true          // один повтор
                    text = await recognize(url: piece)?.text
                }
                try? FileManager.default.removeItem(at: piece)
            }
            if let t = text, !t.isEmpty {
                chunkLog.textLength = t.count
                parts.append((ok: true, text: t))
            } else {
                chunkLog.failed = true
                parts.append((ok: false, text: ""))  // splice вставит […]
            }
            log.chunks.append(chunkLog)
        }

        let joined = Self.splice(parts)
        lastPauseSegments = Self.spliceSegments(parts)
        log.joinedLength = joined.count
        if joined.isEmpty || parts.allSatisfy({ !$0.ok }) {
            recognitionFailure = "Распознавание не справилось — попробуйте ещё раз"
            return nil
        }
        return joined
    }

    // MARK: Чистые функции нарезки и склейки — порт эталона
    // tools/dictation/dictation_splice.py; сходимость со ВСЕМИ векторами
    // dictation_splice_testvectors.json проверяет SpliceParityTests.

    /// Покрытие распознавания целого файла: конец самого позднего
    /// сегмента транскрипции против длительности. <0.85 — результат
    /// частичный, идти в нарезку. Пустые сегменты → 0 (частичный).
    nonisolated static func coverageRatio(
        segments: [(start: Double, duration: Double)],
        duration: Double
    ) -> Double {
        guard duration > 0 else { return 1.0 }
        let end = segments.map { $0.start + $0.duration }.max() ?? 0
        return min(1.0, end / duration)
    }

    /// Точки реза: не ровно по target — в самой тихой точке окна ±window
    /// от цели; тай-брейк при равной тишине — ближе к цели (потом раньше).
    /// Следующая цель = рез + target; хвост короче minTail не режем.
    nonisolated static func pickCutPoints(
        levels: [(t: Double, level: Double)],
        duration: Double,
        target: Double = 30,
        window: Double = 3,
        minTail: Double = 5
    ) -> [Double] {
        var cuts: [Double] = []
        var goal = target
        while goal < duration - minTail {
            let candidates = levels.filter {
                $0.t >= goal - window && $0.t <= goal + window
            }
            let cut = candidates.min {
                ($0.level, abs($0.t - goal), $0.t)
                    < ($1.level, abs($1.t - goal), $1.t)
            }?.t ?? goal
            let rounded = (cut * 100).rounded() / 100
            cuts.append(rounded)
            goal = rounded + target
        }
        return cuts
    }

    /// Границы чанков из точек реза: чанки после первого начинаются на
    /// overlap РАНЬШЕ реза (страховка от реза посреди слова; повторы
    /// стыка снимает дедуп склейки).
    nonisolated static func chunkRanges(
        duration: TimeInterval,
        timeline: [(t: Double, level: Float)] = [],
        overlap: TimeInterval = 1
    ) -> [(start: TimeInterval, duration: TimeInterval)] {
        guard duration > 0 else { return [] }
        let cuts = pickCutPoints(
            levels: timeline.map { ($0.t, Double($0.level)) },
            duration: duration)
        var out: [(TimeInterval, TimeInterval)] = []
        var start: TimeInterval = 0
        for cut in cuts {
            out.append((start, cut - start))
            start = max(0, cut - overlap)
        }
        out.append((start, duration - start))
        return out
    }

    /// Нормализация слова для дедупа: без регистра и знаков (как \w).
    private nonisolated static func normalizeWord(_ word: Substring) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Склейка двух кусков с дедупом перекрытия: максимальный k≤6, где
    /// хвост prev == голова next (нормализованно), — голова next долой.
    nonisolated static func dedupJoinPair(_ prev: String, _ next: String,
                                          maxOverlap: Int = 6) -> String {
        let prevTokens = prev.split(separator: " ")
        let nextTokens = next.split(separator: " ")
        let maxK = min(maxOverlap, prevTokens.count, nextTokens.count)
        if maxK > 0 {
            for k in stride(from: maxK, through: 1, by: -1) {
                let tail = prevTokens.suffix(k).map(normalizeWord)
                let head = nextTokens.prefix(k).map(normalizeWord)
                if tail == head {
                    let rest = nextTokens.dropFirst(k)
                    return rest.isEmpty ? prev
                        : prev + " " + rest.joined(separator: " ")
                }
            }
        }
        return prev + " " + next
    }

    /// Итог склейки: строго append по порядку, отказ чанка (после
    /// повтора) → маркер […]. Никогда не возвращаем только последний
    /// чанк — фикстура старого бага в векторах это ловит.
    /// Вклад каждого чанка в склейку (конкатенация через пробел ==
    /// splice; проверено замком). Это и есть сегменты по паузам STT —
    /// сегментатор источника для смешанного режима (решение владельца
    /// 05.08): диктовка без пунктуации делится там, где человек молчал.
    nonisolated static func spliceSegments(
        _ results: [(ok: Bool, text: String)]) -> [String] {
        var out = ""
        var segments: [String] = []
        for result in results {
            let piece = result.ok
                ? result.text.trimmingCharacters(in: .whitespaces)
                : "[…]"
            if piece.isEmpty { continue }
            let before = out.count
            out = out.isEmpty ? piece : Self.dedupJoinPair(out, piece)
            let added = String(out.dropFirst(before))
                .trimmingCharacters(in: .whitespaces)
            if !added.isEmpty { segments.append(added) }
        }
        return segments
    }

    nonisolated static func splice(_ results: [(ok: Bool, text: String)])
    -> String {
        var out = ""
        for result in results {
            let piece = result.ok
                ? result.text.trimmingCharacters(in: .whitespaces)
                : "[…]"
            if piece.isEmpty { continue }
            out = out.isEmpty ? piece : dedupJoinPair(out, piece)
        }
        return out
    }

    /// Распознавание файла: on-device, без партиалов. КРИТИЧНО: файл с
    /// паузами даёт НЕСКОЛЬКО final-результатов (по одному на кусок речи
    /// между паузами) — собираем ВСЕ через делегата и склеиваем; брать
    /// один финал = потерять всё, кроме последней фразы (баг теста-2).
    /// Возвращает текст + конец последнего сегмента (для покрытия).
    private func recognize(url: URL) async
    -> (text: String, lastSegmentEnd: TimeInterval)? {
        guard let recognizer else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true   // ноль байт наружу
        request.shouldReportPartialResults = false
        // Пунктуация v1.1: границы предложений даёт Сам STT (iOS 16+,
        // on-device) — дальше они сохраняются пивотом и кодами границы
        request.addsPunctuation = true
        // П3а (29.07) + Ф1.3 (30.07): подсказка доменной лексики —
        // штатный механизм SFSpeech: ru-слова словаря + имена контактов
        // + пункты справочника рядом с последней позицией.
        // «--stt-no-context» выключает целиком (A/B-замер фермы).
        if !ProcessInfo.processInfo.arguments.contains("--stt-no-context") {
            request.contextualStrings = Self.domainStrings
                + Self.gazetteerStrings()
        }
        let delegate = FileRecognitionDelegate()
        activeDelegates.insert(delegate)   // удержать до конца таска
        return await withCheckedContinuation { continuation in
            delegate.onDone = { [weak self] text, lastEnd, errorText, words in
                Task { @MainActor in
                    if let errorText { self?.lastRecognitionError = errorText }
                    self?.activeDelegates.remove(delegate)
                }
                // Ф2: терминалы предложений — детерминированный
                // пунктуатор (заглавные + разрывы сегментов), до гейта
                // и без модели. Нет слов — сырой текст как раньше.
                let punctuated = words.isEmpty ? text
                    : Punctuator.punctuate(finals: words)
                continuation.resume(returning: punctuated.map { ($0, lastEnd) })
            }
            recognizer.recognitionTask(with: request, delegate: delegate)
        }
    }

    /// Вырезать кусок файла во временный .m4a (passthrough, без перекодека).
    private func exportChunk(of url: URL,
                             range: (start: TimeInterval, duration: TimeInterval))
    async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return nil
        }
        // контейнер куска — как у источника (passthrough не перекодирует:
        // PCM из .caf в .m4a не влезает)
        let isCaf = url.pathExtension.lowercased() == "caf"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_chunk_\(UUID().uuidString)."
                                    + (isCaf ? "caf" : "m4a"))
        let timescale = CMTimeScale(600)
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: timescale),
            duration: CMTime(seconds: range.duration, preferredTimescale: timescale))
        do {
            try await export.export(to: out, as: isCaf ? .caf : .m4a)
            return out
        } catch {
            lastRecognitionError = "экспорт куска: " + String(describing: error)
            return nil
        }
    }
}

/// Однократный resume для continuation (колбэки распознавателя могут
/// прийти и с результатом, и с ошибкой).
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Делегат распознавания файла: копит ВСЕ final-результаты (файл с
/// паузами даёт их по одному на кусок речи) и отдаёт склейку одним
/// куском по завершению таска. Ошибка с частичными результатами —
/// частичные не выбрасываются (покрытие проверяет вызывающий).
extension SpeechDictation {
    /// Доменные строки для contextualStrings: топ ru-слов словаря
    /// (≥4 букв, по частоте) + имена контактов. Считается один раз.
    nonisolated static let domainStrings: [String] = {
        var out: [String] = []
        if let codec = RMCodec.shared {
            let entries = codec.entries.values
                .filter { $0.layer == "free" && $0.ru != nil }
                .sorted { a, b in a.code < b.code }   // код ~ частота
            for e in entries.prefix(400) {
                for w in e.ru!.split(whereSeparator: { !$0.isLetter })
                where w.count >= 4 {
                    out.append(String(w))
                }
            }
        }
        out += ContactStore.load().map(\.name)
        return Array(Set(out)).sorted()
    }()

    /// Ф1.3: имена пунктов рядом с последней известной позицией.
    /// Позиции нет — пусто (кормить весь мировой справочник нельзя).
    @MainActor
    static func gazetteerStrings() -> [String] {
        guard let fix = LocationProvider.shared.lastFix else { return [] }
        return GazetteerStore.shared.namesNear(lat: fix.lat, lon: fix.lon)
    }

    /// П3б: последние случаи низкой уверенности STT — на Dev-экран,
    /// чтобы владельцу не записывать слова руками.
    nonisolated static let lowConfidenceLog = LowConfidenceLog()

    nonisolated final class LowConfidenceLog: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [String] = []
        func add(_ row: String) {
            lock.lock()
            rows.append(row)
            if rows.count > 30 { rows.removeFirst(rows.count - 30) }
            lock.unlock()
            DictationDebugLog.stage("STT неуверен: " + row)
        }
        var latest: [String] {
            lock.lock(); defer { lock.unlock() }; return rows.reversed()
        }
    }
}

final class FileRecognitionDelegate: NSObject, SFSpeechRecognitionTaskDelegate,
                                     @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var finalsWords: [[Punctuator.Word]] = []
    private var lastEnd: TimeInterval = 0
    private var done = false

    /// (склейка или nil, конец последнего сегмента, текст ошибки,
    ///  слова финалов с таймингами — для пунктуатора Ф2).
    var onDone: (@Sendable (String?, TimeInterval, String?,
                            [[Punctuator.Word]]) -> Void)?

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask,
                               didFinishRecognition result: SFSpeechRecognitionResult) {
        lock.lock()
        let text = result.bestTranscription.formattedString
        if !text.isEmpty { texts.append(text) }
        // Ф2: слова с таймингами — сырьё пунктуатора (заглавные + паузы)
        let words = result.bestTranscription.segments.map {
            Punctuator.Word(text: $0.substring, start: $0.timestamp,
                            duration: $0.duration)
        }
        if !words.isEmpty { finalsWords.append(words) }
        if let segment = result.bestTranscription.segments.last {
            lastEnd = max(lastEnd, segment.timestamp + segment.duration)
        }
        lock.unlock()
        // П3б: сегменты с низкой уверенностью — в локальный лог
        for seg in result.bestTranscription.segments
        where seg.confidence > 0 && seg.confidence < 0.4 {
            SpeechDictation.lowConfidenceLog.add(String(
                format: "«%@» conf %.2f dur %.1fс",
                seg.substring, seg.confidence, seg.duration))
        }
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask,
                               didFinishSuccessfully successfully: Bool) {
        lock.lock()
        let first = !done
        done = true
        let text = texts.isEmpty ? nil : texts.joined(separator: " ")
        let end = lastEnd
        let words = finalsWords
        lock.unlock()
        guard first else { return }
        let errorText = successfully ? nil
            : (task.error.map { String(describing: $0) } ?? "распознавание прервано")
        onDone?(text, end, errorText, words)
    }
}
