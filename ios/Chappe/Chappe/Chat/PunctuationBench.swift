import Foundation
import Speech
import AVFoundation

// ============================================================================
// Бенч пунктуации (Ф4, бриф 31.07) — эмпирика, не документация.
//
// Симптом с устройства: длинная диктовка (877 Б) — ни точек, ни
// запятых; «?» появился только от произнесённого «знак вопроса».
//
// ОДИН аудиофайл (синтез, 5 предложений с паузами) прогоняется в
// четырёх режимах: requiresOnDeviceRecognition {true,false} ×
// addsPunctuation {true,false}. Для каждого — транскрипт и счётчики
// знаков. Итог — Documents/punctuation_bench.json, разбор в отчёте.
// ============================================================================

enum PunctuationBench {

    /// Пять предложений без слов-команд («знак вопроса» не произносим):
    /// границы обязаны появиться от пунктуатора, не от диктовки команд.
    static let sentences = [
        "Мы вышли на рассвете и дошли до перевала за четыре часа",
        "Погода испортилась и мы поставили лагерь у ручья",
        "Вода в ручье чистая но очень холодная",
        "Ты взял с собой запасные батареи для рации",
        "Завтра планируем спуск к деревне если дождь закончится",
    ]

    @MainActor
    static func run() async -> [String: Any] {
        var payload: [String: Any] = ["kind": "punctuation_bench"]
        // Человекочитаемый след в консоли (видно в devicectl --console
        // и в Console.app по слову «бенч») — результат читается без
        // выуживания файла из контейнера
        print("[бенч пунктуации] СТАРТ: синтез \(sentences.count) "
              + "предложений, затем 4 режима распознавания")

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
        payload["recognizer_available"] = recognizer?.isAvailable ?? false
        payload["supports_on_device"] =
            recognizer?.supportsOnDeviceRecognition ?? false

        let auth = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        payload["authorization"] = String(describing: auth)
        guard auth == .authorized, let recognizer else { return payload }

        // Один файл на все четыре режима
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("punctuation_bench.m4a")
        try? FileManager.default.removeItem(at: url)
        do {
            let duration = try await DictationAudioBench.synthesize(
                to: url, phrases: sentences, pause: 1.6)
            payload["audio_seconds"] = duration
        } catch {
            payload["error"] = "синтез: \(error.localizedDescription)"
            return payload
        }

        // Живой прогон на телефоне 31.07: первые распознавания падали
        // «media may be damaged» / «no speech detected» — файл синтеза
        // ещё не финализирован на диске в момент первого чтения.
        // Ждём фактической читаемости и полной длительности.
        payload["file_ready"] = await waitUntilReadable(url)

        var runs: [[String: Any]] = []
        for onDevice in [true, false] {
            for punctuation in [true, false] {
                let label = "onDevice=\(onDevice) punctuation=\(punctuation)"
                var entry: [String: Any] = ["mode": label]
                let started = Date()
                var outcome = await recognize(url: url,
                                              recognizer: recognizer,
                                              onDevice: onDevice,
                                              punctuation: punctuation)
                if case .failure = outcome {
                    // одна повторная попытка после паузы: часть сбоев —
                    // хвост той же гонки финализации
                    try? await Task.sleep(for: .seconds(1))
                    outcome = await recognize(url: url,
                                              recognizer: recognizer,
                                              onDevice: onDevice,
                                              punctuation: punctuation)
                    entry["retried"] = true
                }
                entry["seconds"] = Date().timeIntervalSince(started)
                switch outcome {
                case .success(let text):
                    entry["transcript"] = text
                    entry["chars"] = text.count
                    entry["dots"] = text.filter { $0 == "." }.count
                    entry["commas"] = text.filter { $0 == "," }.count
                    entry["questions"] = text.filter { $0 == "?" }.count
                    entry["exclaims"] = text.filter { $0 == "!" }.count
                    print("[бенч пунктуации] \(label): \(text.count) симв., "
                          + "точек \(entry["dots"] ?? 0), "
                          + "запятых \(entry["commas"] ?? 0), "
                          + "«?» \(entry["questions"] ?? 0) | "
                          + String(text.prefix(90)) + "…")
                case .failure(let message):
                    entry["error"] = message
                    print("[бенч пунктуации] \(label): ОШИБКА — \(message)")
                }
                runs.append(entry)
            }
        }
        payload["runs"] = runs
        print("[бенч пунктуации] ГОТОВО — полный итог: "
              + "Files → Chappe → punctuation_bench.json")
        return payload
    }

    // MARK: Ф3 (30.07) — проверка НОВОГО тракта (пунктуатор) на известных границах

    /// Набор с известной разметкой: 8 предложений, 7 внутренних границ.
    /// №4 — да/нет-вопрос без стартера (ожидаемый промах «?» — честное
    /// ограничение Б6); №6 — имя в середине (ловушка ложной границы);
    /// №7 — wh-вопрос (обязан получить «?»); №8 — имя в начале.
    static let tractSentences = sentences + [
        "Мы встретили Андрея у моста и передали ему запасную рацию",
        "Где вы встали на ночёвку",
        "Марина сказала что вернётся к вечеру",
    ]

    /// Прогон через ПОЛНЫЙ новый тракт живой диктовки: синтез с паузами
    /// → SpeechDictation.recognizeFile (внутри — пунктуатор Ф2).
    @MainActor
    static func runTract() async -> [String: Any] {
        var payload: [String: Any] = ["kind": "punctuator_tract_bench",
                                      "expected_sentences": tractSentences]
        print("[тракт пунктуатора] СТАРТ: \(tractSentences.count) предложений")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("punctuator_tract.m4a")
        try? FileManager.default.removeItem(at: url)
        do {
            let duration = try await DictationAudioBench.synthesize(
                to: url, phrases: tractSentences, pause: 1.6)
            payload["audio_seconds"] = duration
            _ = await waitUntilReadable(url)
            let dictation = SpeechDictation()
            let text = await dictation.recognizeFile(url: url,
                                                     duration: duration)
            payload["recognized"] = text ?? ""
            print("[тракт пунктуатора] ИТОГ: \(text ?? "—")")
        } catch {
            payload["error"] = error.localizedDescription
        }
        return payload
    }

    private enum Outcome {
        case success(String)
        case failure(String)
    }

    /// Дождаться, когда файл синтеза станет читаемым аудиофайлом
    /// ненулевой длины (финализация AVAudioFile отстаёт от возврата
    /// из синтеза). До 5 секунд, шаг 200 мс.
    private static func waitUntilReadable(_ url: URL) async -> Bool {
        for _ in 0..<25 {
            if let file = try? AVAudioFile(forReading: url),
               file.length > 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Распознавание тем же путём, что живая диктовка (несколько
    /// final-результатов через делегата, склейка), но с управляемыми
    /// флагами режима.
    @MainActor
    private static func recognize(url: URL,
                                  recognizer: SFSpeechRecognizer,
                                  onDevice: Bool,
                                  punctuation: Bool) async -> Outcome {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false
        request.addsPunctuation = punctuation
        let delegate = FileRecognitionDelegate()
        var holder: FileRecognitionDelegate? = delegate
        return await withCheckedContinuation { continuation in
            delegate.onDone = { text, _, errorText, _ in
                let outcome: Outcome
                if let text {
                    outcome = .success(text)
                } else {
                    outcome = .failure(errorText ?? "распознаватель не дал текста")
                }
                _ = holder; holder = nil   // удержание до конца таска
                continuation.resume(returning: outcome)
            }
            recognizer.recognitionTask(with: request, delegate: delegate)
        }
    }
}
