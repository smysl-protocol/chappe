//
//  ChappeApp.swift
//  RM
//
//  Created by Gray Kelvin on 24/07/2026.
//

import SwiftUI
import UIKit
import Speech
import AVFoundation

@main
struct ChappeApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                // политика активности «рядом» (фаза 1, 07.08): эфир
                // живёт только при активном приложении — и батарея,
                // и приватность (присутствие не транслируется всегда);
                // фоновое продолжение — фаза 2
                .onChange(of: scenePhase) { _, phase in
                    // галка «Рядом» глушит эфир ЦЕЛИКОМ (поле 13.08,
                    // build 19: снятая галка не выключала BLE — приём,
                    // реклама и ack жили вопреки тумблеру)
                    NearbyTransport.shared.setActive(
                        phase == .active && TransportMode.bleAllowed)
                }
                .task {
                    // Пульс запуска (стенд 11.08): состояние на старте
                    // отличает headless-воскрешение iOS (background,
                    // BLE-реставрация) от ручного открытия (active) —
                    // без этой строки полевые дневники не отвечают на
                    // вопрос «жило ли приложение, когда пакет пришёл».
                    let state = switch UIApplication.shared.applicationState {
                    case .active: "экран"
                    case .background: "фон"
                    default: "переход"
                    }
                    TransportDiary.note("[запуск] приложение поднялось, "
                                        + "состояние: " + state)
                    _ = DeliveryManager.shared   // поднять транспорт
                    NearbyTransport.shared.setActive(TransportMode.bleAllowed)
                    // WP2/WP3 (02.08): BLE-сервис живёт на уровне
                    // приложения; карточка статуса Софи читает его.
                    NetworkStatus.liveSource = {
                        NodeProbe.shared.statusSnapshot()
                    }
                    // тихое восстановление узла по сохранённому id —
                    // без скана; при транспорте «радио» probe уступает
                    // узел транспорту и не подключается вовсе
                    // (иначе транспорт не найдёт узел сканом — регрессия
                    // поймана на первом радиотесте 02.08)
                    NodeProbe.shared.restoreConnection()
                    // Живой грант + ручное открытие приложения →
                    // фоновая сессия шеринга возобновляется (п.2, 29.07)
                    ShareSessionController.shared.resumeOnAppOpen()
                    await Self.runAutoBenchIfRequested()
                }
        }
    }

    /// Авто-замеры: запуск с --bench-long-dictation гонит фикстуру
    /// длинной диктовки, с --bench-test1 — полевой тест 1 (смысловая
    /// петля). Итог — JSON в Documents (File Sharing — забирается
    /// с Мака). В обычных запусках не срабатывает.
    private static func runAutoBenchIfRequested() async {
        // Dev-хуки и бенчи — только DEBUG (подача 06.08)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        // — Веха, фаза 4: сквозной прогон без рук (dev-триггеры) —
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap {
                args.indices.contains($0 + 1) ? args[$0 + 1] : nil
            }
        }
        if let name = value(after: "--set-name") {
            Identity.displayName = name
        }
        if let kind = value(after: "--transport") {
            DeliveryManager.shared.transportKind = kind
        }
        if let peer = value(after: "--peer") {
            DeliveryManager.shared.peerHost = peer
        }
        // проверка пути «рядом» без интернета (фаза 1, 07.08): гасит
        // релей на запуск, чтобы сообщение ушло только прямым путём
        if args.contains("--relay-off") {
            RelayTransport.shared.enabled = false
        }
        if args.contains("--probe-speech") {
            // пульс диктовки (тел 2, сборка 11): дословный статус
            // speech до/после запроса, поддержка on-device, статус
            // микрофона — синхронно в файл (краш не проглотит)
            func markSpeech(_ s: String) {
                TransportDiary.note("[speech-зонд] " + s)
                if let docs = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask).first {
                    let url = docs.appendingPathComponent("speech_probe.txt")
                    let prev = (try? String(contentsOf: url,
                                            encoding: .utf8)) ?? ""
                    try? Data((prev + s + "\n").utf8)
                        .write(to: url, options: .atomic)
                }
            }
            let before = SFSpeechRecognizer.authorizationStatus()
            markSpeech("статус ДО запроса: \(before.rawValue) "
                       + "(\(SpeechDictation.speechStatusName(before)))")
            let rec = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
            markSpeech("recognizer ru-RU: \(rec == nil ? "nil" : "есть"), "
                       + "supportsOnDevice: "
                       + "\(rec?.supportsOnDeviceRecognition ?? false)")
            let granted = await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            markSpeech("статус ПОСЛЕ запроса: \(granted.rawValue) "
                       + "(\(SpeechDictation.speechStatusName(granted)))")
            let mic = AVAudioApplication.shared.recordPermission
            markSpeech("микрофон: \(mic.rawValue)")
        }
        if args.contains("--probe-aware") {
            // изоляция краша знакомства телефонов (стенд 11.08):
            // краш-кандидаты по шагам, без системного экрана.
            // Метки — СИНХРОННО в свой файл: дневник пишет async и
            // теряет буфер при краше (первый прогон умер без следов)
            func markAware(_ s: String) {
                TransportDiary.note("[aware-зонд] " + s)
                if let docs = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask).first {
                    let url = docs.appendingPathComponent("aware_probe.txt")
                    let prev = (try? String(contentsOf: url,
                                            encoding: .utf8)) ?? ""
                    try? Data((prev + s + "\n").utf8)
                        .write(to: url, options: .atomic)
                }
            }
            markAware("зонд стартовал")
            if #available(iOS 26.0, *) {
                let verdict = await NearbyPairing.isolationProbe(
                    mark: markAware)
                markAware("итог: " + verdict)
            } else {
                markAware("iOS < 26")
            }
        }
        if args.contains("--relay-on") {
            RelayTransport.shared.enabled = true
        }
        if let host = value(after: "--net-probe") {
            // проба: доходит ли TCP до peer:47474 (диагноз AP-изоляции)
            let result = await NetProbe.tcp(host: host, port: 47474)
            if let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask).first {
                try? Data(result.utf8).write(
                    to: docs.appendingPathComponent("net_probe.txt"),
                    options: .atomic)
            }
        }
        if args.contains("--export-identity") {
            if let payload = ContactStore.myPayloadBase64(),
               let docs = FileManager.default.urls(
                   for: .documentDirectory, in: .userDomainMask).first {
                let info = payload + "\n" + (NetInfo.myIPv4() ?? "?")
                    + "\n" + (Identity.myFingerprint() ?? "?")
                try? Data(info.utf8).write(
                    to: docs.appendingPathComponent("identity_payload.txt"),
                    options: .atomic)
            }
        }
        if let payload = value(after: "--add-contact"),
           let contact = ContactStore.parse(payload) {
            ContactStore.upsert(contact)   // dev-путь; в UI — подтверждение
        }
        if let contactID = value(after: "--send-test1-to") {
            await sendPipeline(text: DictationFixtures.fieldTest1,
                               contactID: contactID,
                               marker: "send_test1_result.json")
        }
        // Ночной прогон 02.08: локальная модель — чтобы работал
        // смысловой кодек, а не только текстовый откат
        if args.contains("--use-local-model") {
            _ = LLMModelConfig.activateLocalIfInstalled()
            await ModelScheduler.shared.invalidateProvider()
        }
        // Пакетная отправка: один запуск — много сообщений разной длины
        if let contactID = value(after: "--send-batch") {
            let count = Int(value(after: "--batch-count") ?? "12") ?? 12
            await sendBatch(contactID: contactID, count: count)
        }
        if let contactID = value(after: "--send-text-to"),
           let text = value(after: "--text") {
            // произвольный текст контакту (живая переписка при прогонах)
            await sendPipeline(text: text, contactID: contactID,
                               marker: "send_text_result.json")
        }
        if let contactID = value(after: "--send-reply-to") {
            await sendPipeline(
                text: "Принял вас понял ждём у старого кафе в 7 30 наличные "
                    + "возьмём с собой держитесь там берегите батарею",
                contactID: contactID,
                marker: "send_reply_result.json")
        }
        if let text = value(after: "--bench-text") {
            // произвольная текстовая фикстура через настоящий конвейер
            await runBench(source: text, kind: "custom_text_bench",
                           file: "custom_text_bench.json")
        }
        if args.contains("--bench-long-dictation") {
            await runBench(source: DictationFixtures.longTrip,
                           kind: "long_dictation_bench",
                           file: "long_dictation_bench.json")
        }
        if args.contains("--bench-test1") {
            await runBench(source: DictationFixtures.fieldTest1,
                           kind: "field_test1_bench",
                           file: "field_test1_bench.json")
        }
        if args.contains("--bench-dictation-audio") {
            // сквозной прогон со звуком: синтез тест-1 с паузами →
            // распознавание тем же путём, что живая диктовка
            let payload = await DictationAudioBench.run()
            writeBenchJSON(payload, file: "dictation_audio_bench.json")
        }
        if args.contains("--bench-farm") {
            // ферма диктовок: распознать все Documents/farm_*.wav
            let payload = await DictationAudioBench.farm()
            writeBenchJSON(payload, file: "farm_recognized.json")
        }
        if args.contains("--bench-whisper") {
            // репро крэша шёпота: тот же путь, что HumanChatModel.whisper,
            // с прогресс-файлом на каждую стадию (крэш укажет место)
            await runWhisperBench()
        }
        if args.contains("--bench-determinism") {
            // приоритет №1: один вход 3 раза — выходы байт в байт
            let payload = await DictationAudioBench.determinism()
            writeBenchJSON(payload, file: "determinism_bench.json")
        }
        if args.contains("--bench-map-region") {
            // WP1 карты: реальный вес и время скачивания региона
            await runMapRegionBench()
        }
        if args.contains("--bench-punctuation") {
            // Ф4 (31.07): один файл × 4 режима распознавания —
            // эмпирика по пунктуации, не documentation-driven
            let payload = await PunctuationBench.run()
            writeBenchJSON(payload, file: "punctuation_bench.json")
        }
        if args.contains("--bench-punctuator") {
            // Ф3 (30.07): известные границы через ПОЛНЫЙ новый тракт
            // (recognizeFile + пунктуатор) — верно/ложно/пропущено
            let payload = await PunctuationBench.runTract()
            writeBenchJSON(payload, file: "punctuator_tract.json")
        }
        #endif
    }

    /// WP1 слоя карты: скачивает Гибралтарский пролив (50×50 км, z0–14)
    /// настоящим RegionDownloader'ом и пишет фактический вес и время.
    /// Нужен интернет; итог — Documents/map_region_bench.json.
    @MainActor
    private static func runMapRegionBench() async {
        var payload: [String: Any] = ["kind": "map_region_bench",
                                      "bbox": "35.85,-5.90,36.30,-5.30",
                                      "zoom": "0-14"]
        let started = DispatchTime.now()
        defer { writeBenchJSON(payload, file: "map_region_bench.json") }

        let bbox = RegionBBox(minLat: 35.85, minLon: -5.90,
                              maxLat: 36.30, maxLon: -5.30)
        payload["estimated_bytes"] = RegionDownloader.shared
            .estimatedSizeBytes(bbox: bbox, minZoom: 0, maxZoom: 14)
        do {
            try RegionDownloader.shared.startDownload(
                name: "Гибралтар (бенч)", bbox: bbox, minZoom: 0, maxZoom: 14)
        } catch {
            payload["error"] = error.localizedDescription
            return
        }
        // ждём готовности; каждые 30 с фиксируем прогресс в файл
        for second in 1...900 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            RegionDownloader.shared.reloadRegions()
            guard let region = RegionDownloader.shared.regions
                .first(where: { $0.name == "Гибралтар (бенч)" }) else { continue }
            payload["bytes"] = region.sizeBytes ?? 0
            payload["state"] = String(describing: region.state)
            if region.state == .ready || region.state == .stale {
                payload["elapsed_s"] = Double(
                    DispatchTime.now().uptimeNanoseconds
                    - started.uptimeNanoseconds) / 1e9
                return
            }
            if second % 30 == 0 {
                writeBenchJSON(payload, file: "map_region_bench.json")
            }
        }
        payload["error"] = "не дождались готовности за 900 с"
    }

    /// Отправка контакту настоящим путём: конвейер → sealed → очередь →
    /// транспорт. Итог — в Documents (для прогона вехи).
    @MainActor
    /// Ночной прогон: корпус сообщений разной длины и жанра через
    /// НАСТОЯЩИЙ конвейер, с паузами под дьюти-цикл эфира.
    private static func sendBatch(contactID: String, count: Int) async {
        let corpus = [
            "ок",
            "да, понял",
            "выехал",
            "буду через двадцать минут",
            "возьми две бутылки воды и аптечку",
            "встречаемся у северного входа рынка в семь утра",
            "погода портится, ветер усиливается, спускаемся ниже к реке",
            "если связи не будет до вечера — иди к лодочной станции и жди там",
            "поедем завтра в отель на берегу реки, если погода хорошая — "
            + "выдвинемся в 6 утра, если нет — наверно чуть попозже",
            "нужны бинты и вода на троих, у одного рассечена голова, "
            + "идти может сам, ждём помощь у моста, координаты передам следом",
            "короче слушай тут такое дело в общем мы вроде как решили что "
            + "лучше будет если ты подъедешь пораньше часам к шести потому "
            + "что потом там будет не проехать совсем",
            "проверка длинного сообщения с фрагментацией: " +
            String(repeating: "это предложение повторяется чтобы набрать "
                   + "длину и заставить конверт разбиться на несколько "
                   + "пакетов. ", count: 4),
        ]
        for index in 0..<count {
            let text = corpus[index % corpus.count]
            await sendPipeline(text: text, contactID: contactID,
                               marker: "batch_\(index).json")
            // пауза: дать эфиру уйти и не выжрать дьюти-цикл
            try? await Task.sleep(for: .seconds(12))
        }
    }

    private static func sendPipeline(text: String, contactID: String,
                                     marker: String) async {
        var payload: [String: Any] = ["kind": "send", "to": contactID]
        let started = DispatchTime.now()
        defer { writeBenchJSON(payload, file: marker) }
        guard let contact = ContactStore.load()
            .first(where: { $0.id == contactID }) else {
            payload["error"] = "контакт не найден"
            return
        }
        let outcome = await SemanticEncoder.prepare(russian: text)
        var entry: ChatEntry
        do {
            let queued: Outbox.QueuedMessage
            switch outcome {
            case .semantic(let encoded):
                entry = ChatEntry(kind: .outgoing, text: encoded.rendered)
                // wire-форма: [хеш таблицы][блоб] (сверка версий, п.5)
                let wire = RMCodec.shared?.wireBlob(encoded.blob)
                    ?? encoded.blob
                entry.semanticBlob = wire
                queued = try Outbox.enqueueSealed(
                    innerCodec: Envelope.codecSemantic,
                    data: wire, to: contact, entryID: entry.id)
                payload["outcome"] = "semantic"
                payload["blob_bytes"] = encoded.blob.count
            case .text(let reason, _):
                entry = ChatEntry(kind: .outgoing, text: text)
                // гейт размера: store против zlib, меньший побеждает
                let (codec, data) = TextCodec.best(text)
                queued = try Outbox.enqueueSealed(
                    innerCodec: codec, data: data,
                    to: contact, entryID: entry.id)
                payload["outcome"] = "text (\(reason))"
            }
            entry.envelopeBytes = queued.totalBytes
            entry.wireMsgID = Int(queued.msgID)   // для ACK и прочтения
            var log = HumanChatStore.loadLog(contactID: contact.id)
            log.append(entry)
            HumanChatStore.saveLog(log, contactID: contact.id)
            DeliveryManager.shared.pushQueue()
            payload["packets"] = queued.packetsHex.count
            payload["total_bytes"] = queued.totalBytes
            payload["ms"] = Double(DispatchTime.now().uptimeNanoseconds
                                   - started.uptimeNanoseconds) / 1e6
        } catch {
            payload["error"] = String(describing: error)
        }
    }

    @MainActor
    private static func runWhisperBench() async {
        func mark(_ stage: String) {
            if let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask).first {
                try? Data((stage + "\n").utf8).write(
                    to: docs.appendingPathComponent("whisper_bench_stage.txt"),
                    options: .atomic)
            }
        }
        mark("start")
        let question = "Что ответить если он предлагает выйти в шторм?"
        do {
            mark("toolBlock…")
            let toolBlock = await SophieChatModel.toolBlockIfNeeded(for: question)
            mark("toolBlock ok: \(toolBlock?.count ?? -1)")
            // Транскрипт — 1-в-1 как HumanChatModel.whisper(): живой лог
            let entries = HumanChatStore.loadLog()
            let transcript = entries
                .filter { $0.kind == .outgoing }
                .suffix(12)
                .map { "Я собеседнику: \($0.text)" }
                .joined(separator: "\n")
            mark("транскрипт: \(transcript.count) симв. из \(entries.count) записей")
            var user = ""
            if !transcript.isEmpty {
                user += "Переписка с человеком (для контекста):\n\(transcript)\n\n"
            }
            if let toolBlock { user += toolBlock + "\n" }
            user += "Вопрос пользователя (шёпотом, собеседник не видит): "
                  + question
            let system = try SophiePrompt.systemPrompt()
                + "\n\nСейчас это ШЁПОТ внутри чата с человеком: твой ответ "
                + "видит только пользователь, собеседнику ничего не уходит. "
                + "Отвечай кратко."
            mark("генерация…")
            let request = LLMRequest(prompt: user, systemPrompt: system,
                                     maxTokens: 300)
            let response = try await ModelScheduler.shared
                .withProvider(.interactive) { provider in
                    try await provider.generateStreaming(request) { _ in }
                }
            mark("готово: \(response.tokensGenerated) токенов, "
               + "\(response.text.prefix(120))")
        } catch {
            mark("ошибка: \(error)")
        }
    }

    private static func writeBenchJSON(_ payload: [String: Any], file: String) {
        if let docs = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask).first,
           let data = try? JSONSerialization.data(
               withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: docs.appendingPathComponent(file),
                            options: .atomic)
        }
    }

    private static func runBench(source: String, kind: String,
                                 file: String) async {
        let started = DispatchTime.now()
        let outcome = await SemanticEncoder.prepare(russian: source)
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds
                             - started.uptimeNanoseconds) / 1e6

        var payload: [String: Any] = [
            "kind": kind,
            "source_words": SemanticEncoder.wordCount(source),
            "total_ms": totalMs,
        ]
        switch outcome {
        case .semantic(let e):
            payload["outcome"] = "semantic"
            payload["chunks"] = e.chunkCount
            payload["pivot_ms"] = e.pivotMillis
            payload["pivot"] = e.pivot
            payload["blob_bytes"] = e.blob.count
            payload["blob_hex"] = e.blob.map { String(format: "%02x", $0) }
                .joined()
            payload["rendered"] = e.rendered
            payload["loop_rewritten"] = e.loopRewritten ?? ""
            // зеркало получателя: чистая развёртка таблицей, без петли
            if let codec = RMCodec.shared,
               let units = try? codec.decode(e.blob) {
                payload["mirror_ru"] = codec.render(units)
                payload["mirror_en"] = codec.render(units, lang: "en")
            }
        case .text(let reason, _):
            payload["outcome"] = "text"
            payload["reason"] = reason
        }
        if let docs = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask).first,
           let data = try? JSONSerialization.data(
               withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: docs.appendingPathComponent(file),
                            options: .atomic)
        }
    }
}
