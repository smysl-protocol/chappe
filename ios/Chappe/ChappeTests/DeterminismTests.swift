import Foundation
import Testing
import Speech
import AVFoundation
@testable import Chappe

// ============================================================================
// Детерминизм (приоритет №1 разбора нестабильности): один и тот же вход
// 3 раза — одинаковый выход. Модельная часть (пивоты байт в байт)
// проверяется на устройстве бенчем --bench-determinism; здесь — то, что
// доступно сьюте: распознавание короткого файла (если on-device ru есть
// в среде) и детерминированность чистых функций конвейера.
// ============================================================================

struct DeterminismTests {

    @Test("Чистые функции: 3 прогона — байт в байт")
    func pureFunctionsDeterministic() {
        let levels: [(t: Double, level: Double)] = stride(
            from: 0.0, through: 70.0, by: 0.1).map {
            ($0, Double(Int($0 * 7919) % 100) / 100 - 0.5)
        }
        let parts: [(ok: Bool, text: String)] = [
            (true, "первая часть про дождь"),
            (false, ""),
            (true, "дождь третья часть про кафе"),
        ]
        var cutRuns: Set<[Double]> = []
        var spliceRuns: Set<String> = []
        for _ in 0..<3 {
            cutRuns.insert(SpeechDictation.pickCutPoints(levels: levels,
                                                         duration: 70))
            spliceRuns.insert(SpeechDictation.splice(parts))
        }
        #expect(cutRuns.count == 1)
        #expect(spliceRuns.count == 1)
    }

    @Test("Распознавание одного короткого файла 3 раза — одинаковый текст")
    @MainActor
    func recognitionDeterministicOnShortFile() async throws {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
        guard recognizer?.supportsOnDeviceRecognition == true,
              SFSpeechRecognizer.authorizationStatus() == .authorized ||
              SFSpeechRecognizer.authorizationStatus() == .notDetermined,
              let voice = AVSpeechSynthesisVoice(language: "ru-RU") else {
            // в симуляторе on-device ru обычно недоступен — проверка
            // выполняется бенчем --bench-determinism на устройстве
            _ = AVSpeechSynthesisVoice(language: "ru-RU")
            return
        }
        _ = voice

        // короткий синт-файл через тот же бенч-синтезатор недоступен из
        // тестов (private); пишем свой минимальный
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("det_test.caf")
        try? FileManager.default.removeItem(at: url)
        let synth = AVSpeechSynthesizer()
        var file: AVAudioFile?
        var frames: Int64 = 0
        var rate: Double = 22_050
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(
                string: "возьми три бутылки воды и хлеб")
            utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            nonisolated(unsafe) var resumed = false
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !resumed { resumed = true; c.resume() }
                } else {
                    if file == nil {
                        file = try? AVAudioFile(forWriting: url,
                                                settings: pcm.format.settings)
                        rate = pcm.format.sampleRate
                    }
                    try? file?.write(from: pcm)
                    frames += Int64(pcm.frameLength)
                }
            }
        }
        file = nil   // финализировать
        guard frames > 0 else { return }   // синтез недоступен — не падаем

        let duration = Double(frames) / rate
        var texts: [String] = []
        for _ in 0..<3 {
            let dictation = SpeechDictation()
            texts.append(await dictation.recognizeFile(url: url,
                                                       duration: duration) ?? "")
        }
        try? FileManager.default.removeItem(at: url)
        #expect(Set(texts).count == 1, "распознавание недетерминировано: \(texts)")
    }
}
