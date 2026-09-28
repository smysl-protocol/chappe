import Foundation
import AVFoundation

// ============================================================================
// Авто-бенч диктовки со звуком: тест-1 синтезируется голосом (ru-RU,
// AVSpeechSynthesizer, офлайн) с паузами 2–3 с между фразами и одной
// паузой 10 с посередине, файл идёт ТЕМ ЖЕ путём, что живая диктовка
// (recognizeFile: целиком → покрытие → чанки → склейка). Итог + debug-лог
// уходят в Documents. Запуск: --bench-dictation-audio.
// ============================================================================

@MainActor
enum DictationAudioBench {

    /// Тест-1 по фразам; после 2-й — пауза 10 с, между остальными 2.5 с.
    static let phrases = [
        "Слушай мы выезжаем примерно через 40 минут наверное",
        "потому что дождь очень сильный зарядил дорога рядом с рынком снова затоплена",
        "так что мы пойдём через мост встретимся наверху у старого кафе",
        "в 7 или лучше в 7 30",
        "возьми 3 бутылки воды и хлеб потому что у нас всё закончилось",
        "и помни зарядить телефон мой аккумулятор сдох вчера",
    ]

    static func run() async -> [String: Any] {
        var payload: [String: Any] = ["kind": "dictation_audio_bench"]
        // PCM CAF: без перекодека — файл гарантированно честный
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synth_test1.caf")
        try? FileManager.default.removeItem(at: url)

        do {
            let duration = try await synthesize(to: url)
            payload["audio_seconds"] = duration

            let dictation = SpeechDictation()
            let text = await dictation.recognizeFile(url: url,
                                                     duration: duration)
            payload["recognized"] = text ?? "(отказ)"
            payload["recognized_chars"] = text?.count ?? 0
            if let error = dictation.lastRecognitionError {
                payload["last_error"] = error
            }
            if let log = DictationDebugLog.load(),
               let data = try? JSONEncoder().encode(log),
               let object = try? JSONSerialization.jsonObject(with: data) {
                payload["debug_log"] = object
            }
            try? FileManager.default.removeItem(at: url)
        } catch {
            payload["error"] = String(describing: error)
        }
        return payload
    }

    /// Ферма диктовок: распознать все Documents/farm_*.wav тем же
    /// recognizeFile, что живая диктовка. Результаты пишутся
    /// прогрессивно в Documents/farm_recognized.json (устойчивость
    /// к прерыванию), конвейер дальше гоняет Мак (llama-server).
    static func farm() async -> [String: Any] {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("farm_")
                   && $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var results: [[String: Any]] = []
        for url in files {
            guard let audio = try? AVAudioFile(forReading: url) else {
                results.append(["file": url.lastPathComponent,
                                "error": "не читается"])
                continue
            }
            let duration = Double(audio.length)
                / audio.processingFormat.sampleRate
            let dictation = SpeechDictation()
            let started = DispatchTime.now()
            let text = await dictation.recognizeFile(url: url,
                                                     duration: duration)
            let ms = Double(DispatchTime.now().uptimeNanoseconds
                            - started.uptimeNanoseconds) / 1e6
            results.append([
                "file": url.lastPathComponent,
                "duration_s": duration,
                "recognize_ms": ms,
                "text": text ?? "",
                "path": DictationDebugLog.load()?.path ?? "",
            ])
            // прогрессивная запись — частичные результаты не теряются
            let payload: [String: Any] = ["kind": "farm",
                                          "done": results.count,
                                          "total": files.count,
                                          "results": results]
            if let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: docs.appendingPathComponent(
                    "farm_recognized.json"), options: .atomic)
            }
        }
        return ["kind": "farm", "done": results.count,
                "total": files.count, "results": results]
    }

    /// Детерминизм (блокер заморозки словаря): одно СОХРАНЁННОЕ аудио
    /// «Мы вышли раньше» — 3 прогона всей цепочки (распознавание →
    /// пивот → петля → коды). Пивот и блоб обязаны совпасть БАЙТ В БАЙТ.
    static func determinism() async -> [String: Any] {
        var payload: [String: Any] = ["kind": "determinism_bench"]
        let source = "Мы вышли раньше, чем думали. Сейчас 07:20, будем "
            + "у моста примерно через час. Если дорога сухая, дойдём "
            + "быстрее, но я не уверен."

        // Сохранённое аудио: живёт в Documents и переиспользуется между
        // запусками — прогоны идут по ОДНОМУ файлу, не по свежему синтезу
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else {
            payload["error"] = "нет Documents"
            return payload
        }
        let url = docs.appendingPathComponent("det_my_vyshli.caf")
        do {
            var duration: Double
            if FileManager.default.fileExists(atPath: url.path) {
                let file = try AVAudioFile(forReading: url)
                duration = Double(file.length)
                    / file.processingFormat.sampleRate
                payload["audio"] = "существующее"
            } else {
                duration = try await synthesize(to: url, phrases: [source],
                                                pause: 1)
                payload["audio"] = "синтезировано и сохранено"
            }

            // а) распознавание одного файла 3 раза
            var texts: [String] = []
            for _ in 0..<3 {
                let dictation = SpeechDictation()
                texts.append(await dictation.recognizeFile(
                    url: url, duration: duration) ?? "(отказ)")
            }
            payload["recognized"] = texts
            payload["recognized_identical"] = Set(texts).count == 1

            // б) полный конвейер от распознанного текста 3 раза:
            // пивот и блоб — байт в байт (hex), не только длина
            var pivots: [String] = []
            var blobsHex: [String] = []
            var fields: [String] = []
            for _ in 0..<3 {
                switch await SemanticEncoder.prepare(russian: texts[0]) {
                case .semantic(let e):
                    pivots.append(e.pivot)
                    blobsHex.append(e.blob
                        .map { String(format: "%02x", $0) }.joined())
                    fields.append(e.rendered)
                case .text(let reason, _):
                    pivots.append("TEXT: " + reason)
                    blobsHex.append("")
                    fields.append("")
                }
            }
            payload["pivots"] = pivots
            payload["pivots_identical"] = Set(pivots).count == 1
            payload["blobs_hex"] = blobsHex
            payload["blobs_identical"] = Set(blobsHex).count == 1
            payload["fields_identical"] = Set(fields).count == 1
        } catch {
            payload["error"] = String(describing: error)
        }
        return payload
    }

    /// Синтез фраз с паузами в .m4a (AAC). Возвращает длительность файла.
    private static func synthesize(to url: URL) async throws -> Double {
        try await synthesize(to: url, phrases: phrases, pause: 2.5)
    }

    /// internal: синтез переиспользует бенч пунктуации (Ф4, 31.07)
    static func synthesize(to url: URL, phrases: [String],
                           pause defaultPause: Double) async throws
    -> Double {
        guard let voice = AVSpeechSynthesisVoice(language: "ru-RU") else {
            throw NSError(domain: "chappe.bench", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "нет голоса ru-RU для синтеза"])
        }
        let synth = AVSpeechSynthesizer()
        var file: AVAudioFile?
        var format: AVAudioFormat?
        var frames: Int64 = 0

        func write(_ pcm: AVAudioPCMBuffer) throws {
            if file == nil {
                format = pcm.format
                // PCM как есть — настройки из формата буфера синтеза
                file = try AVAudioFile(forWriting: url,
                                       settings: pcm.format.settings)
            }
            try file?.write(from: pcm)
            frames += Int64(pcm.frameLength)
        }

        func silence(_ seconds: Double) throws {
            guard let format else { return }
            let count = AVAudioFrameCount(seconds * format.sampleRate)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: count) else { return }
            pcm.frameLength = count
            // буфер обнуляем сами — инициализация не гарантирована
            if let ch = pcm.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    ch[c].update(repeating: 0, count: Int(count))
                }
            } else if let ch = pcm.int16ChannelData {
                for c in 0..<Int(format.channelCount) {
                    ch[c].update(repeating: 0, count: Int(count))
                }
            }
            try write(pcm)
        }

        for (index, phrase) in phrases.enumerated() {
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = voice
            utterance.rate = 0.45
            // resume строго один раз — на нулевом буфере конца фразы
            let once = OnceResumeBox()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                synth.write(utterance) { buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 {
                        once.run { c.resume() }
                    } else {
                        try? write(pcm)
                    }
                }
            }
            // паузы: в полном тест-1 после второй фразы — 10 с
            if index < phrases.count - 1 {
                try silence(index == 1 && phrases.count > 4 ? 10 : defaultPause)
            }
        }
        guard let format, frames > 0 else {
            throw NSError(domain: "chappe.bench", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "синтез не дал аудио"])
        }
        return Double(frames) / format.sampleRate
    }
}

/// Однократный resume (нулевой буфер конца фразы может прийти не один).
private final class OnceResumeBox: @unchecked Sendable {
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
