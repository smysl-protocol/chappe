//
//  SOSExtractView.swift
//  R+M — проверка сквозного потока SOS→JSON
//
//  Текст → LLM (через LLMProvider, сейчас RemoteProvider → llama-server
//  на Маке) → жёсткая схема → человекочитаемая карточка + сырой JSON.
//
//  Требуется: llama-server запущен на Маке, телефон в той же Wi-Fi
//  (см. docs/remote_llm_setup.md).
//

import SwiftUI
import Combine

@MainActor
final class SOSExtractModel: ObservableObject {

    /// Предзаполнено сообщением из бенчмарка — проверка в одно нажатие.
    @Published var input =
        "Мы на северном пляже за третьим пирсом, у моего друга сильно порезана "
      + "нога, кровь не останавливается уже минут двадцать, нас тут трое, "
      + "аптечки нет, телефон почти сел, нужен кто-то с бинтами и лодка чтобы вывезти."

    @Published var isLoading = false
    @Published var report: SOSReport?
    @Published var rawJSON: String?
    @Published var tokensPerSecond: Double = 0
    @Published var errorMessage: String?
    @Published var radio: RadioDemoResult?

    /// Итог прогона «пакет через эфир» — полная цепочка без железа.
    struct RadioDemoResult {
        let packetSize: Int          // байт в envelope-пакете
        let packetHex: String
        let copiesSent: Int          // SOS повторяют — пакет крошечный
        let copiesArrived: Int
        let bytesOnAir: Int          // байт реально ушло в эфир
        let channelReport: String    // статистика канала по-русски
        let seed: UInt64             // seed симуляции (для воспроизведения)
        let received: SOSMessage?    // что развернула принимающая сторона
        let receivedNeeds: String    // человекочитаемые расшифровки
        let receivedSeverity: String
        let receivedInjury: String
        let receivedCoords: String
    }

    private var runTask: Task<Void, Never>?

    func extract() {
        runTask = Task { await run() }
    }

    func cancel() {
        Task { await ModelScheduler.shared.cancelActive() }
        runTask?.cancel()
    }

    private func run() async {
        isLoading = true
        errorMessage = nil
        report = nil
        rawJSON = nil
        radio = nil
        defer { isLoading = false }

        do {
            let request = LLMRequest(
                prompt: SOSExtraction.prompt(for: input),
                maxTokens: 200,
                samplingOverride: .extraction)

            // Через планировщик как P0 (SOS-конвейер, sophie_presence §5).
            // Схема/валидация/repair — внутри StructuredLLM, как раньше.
            let result = try await ModelScheduler.shared.withProvider(.sos) { provider in
                try await StructuredLLM.callRaw(
                    provider: provider,
                    request: request,
                    spec: SOSExtraction.spec,
                    as: SOSReport.self,
                    validate: SOSReport.validate(_:))
            }

            report = result.value
            rawJSON = Self.prettyJSON(result.rawJSON)
            tokensPerSecond = result.tokensPerSecond

            // Цепочка дальше: JSON → envelope-байты → эфир → байты → структура
            radio = Self.runRadioDemo(report: result.value)
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
        }
    }

    /// Полная цепочка после извлечения: сборка envelope-пакета,
    /// прогон через симулятор LoRa с потерями, разворот на «приёме».
    /// Доказательство, что весь стек работает без железа.
    private static func runRadioDemo(report: SOSReport) -> RadioDemoResult? {
        // Координаты — GPS-заглушка (Бали, как в тест-векторах).
        // Настоящий GPS подключим отдельно; модель координат не касается.
        let mockLat = 8.71, mockLon = 115.17

        let msgID = Envelope.newMsgID()
        let sos = NeedsMapping.makeSOSMessage(from: report, msgID: msgID,
                                              lat: mockLat, lon: mockLon)
        guard let packet = try? sos.encode() else { return nil }

        // Канал с «плохим радио»: 30% потерь, 10% дубликатов, 20% перестановок.
        // Seed = msgID: каждый прогон свой, но воспроизводимый по seed.
        let seed = UInt64(msgID)
        let channel = LoRaChannel(loss: 0.30, duplicate: 0.10, reorder: 0.20,
                                  seed: seed)
        let copies = 3                    // SOS повторяют — это дёшево
        for _ in 0..<copies { channel.send(packet) }
        let arrived = channel.deliverAll()

        // «Принимающая сторона» (тот же телефон, эмуляция): разворачиваем
        var received: SOSMessage?
        if let first = arrived.first,
           case .sos(let decoded) = try? EnvelopeDecoder.decode(first) {
            received = decoded
        }

        let needsText = received.map { msg in
            msg.needs.sorted()
                .compactMap { NeedsMapping.bitNames[$0] }
                .joined(separator: ", ")
        } ?? "—"
        let coordsText = received.flatMap { msg in
            msg.lat.map { String(format: "%.4f, %.4f (~300×600 м)", $0, msg.lon!) }
        } ?? "—"

        return RadioDemoResult(
            packetSize: packet.count,
            packetHex: packet.map { String(format: "%02X", $0) }.joined(separator: " "),
            copiesSent: copies,
            copiesArrived: arrived.count,
            bytesOnAir: (channel.stats.sent - channel.stats.oversize
                         + channel.stats.duplicated) * packet.count,
            channelReport: channel.report,
            seed: seed,
            received: received,
            receivedNeeds: needsText,
            receivedSeverity: received.flatMap { NeedsMapping.severityNames[$0.severity] } ?? "—",
            receivedInjury: received.flatMap { NeedsMapping.injuryNames[$0.injury] } ?? "—",
            receivedCoords: coordsText)
    }

    private static func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return raw }
        return text
    }

    private static func friendlyMessage(for error: Error) -> String {
        guard let llm = error as? LLMError else {
            return "Ошибка: \(error.localizedDescription)"
        }
        switch llm {
        case .modelLoadFailed(let reason):
            return "Сервер недоступен. Проверь: llama-server запущен на Маке, "
                 + "телефон в той же Wi-Fi, IP в конфиге верный.\n(\(reason))"
        case .modelNotLoaded:
            return "Модель не загружена — повтори попытку."
        case .generationFailed(let reason):
            return "Генерация не удалась: \(reason)"
        case .cancelled:
            return "Отменено."
        case .invalidStructuredResult(let reason):
            return "Модель не выдала корректный JSON даже после repair-попытки: "
                 + reason
        case .structuredOutputUnsupported:
            return "Этот провайдер не поддерживает схему."
        case .modelNotFound(let path):
            return "Файл модели не найден: \(path)"
        case .providerUnavailable(let reason):
            return "Провайдер недоступен: \(reason)"
        }
    }
}

struct SOSExtractView: View {
    @StateObject private var model = SOSExtractModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Сообщение") {
                    TextEditor(text: $model.input)
                        .frame(minHeight: 120)
                        .font(.body)
                }
                .listRowBackground(RMDesign.surface1)

                Section {
                    if model.isLoading {
                        HStack {
                            ProgressView()
                            Text("Извлекаю…")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Отмена") { model.cancel() }
                        }
                    } else {
                        Button {
                            model.extract()
                        } label: {
                            Label("Извлечь SOS", systemImage: "cross.case.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RMDesign.danger)   // SOS — токен опасности
                        .disabled(model.input.trimmingCharacters(
                            in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .listRowBackground(RMDesign.surface1)

                if let message = model.errorMessage {
                    Section("Ошибка") {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                    .listRowBackground(RMDesign.surface1)
                }

                if let report = model.report {
                    Section("Результат") {
                        LabeledContent("Тип", value: report.typeLabel)
                        LabeledContent("Срочность", value: report.severityLabel)
                        LabeledContent("Людей", value: "\(report.peopleCount)")
                        LabeledContent("Травма", value: report.injuryLabel)
                        LabeledContent("Нужно", value: report.needsLabel)
                        if model.tokensPerSecond > 0 {
                            LabeledContent("Скорость",
                                           value: String(format: "%.1f tok/s",
                                                         model.tokensPerSecond))
                        }
                    }
                    .listRowBackground(RMDesign.surface1)
                }

                if let radio = model.radio {
                    Section("Пакет (envelope)") {
                        LabeledContent("Размер", value: "\(radio.packetSize) байт")
                        Text(radio.packetHex)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .listRowBackground(RMDesign.surface1)

                    Section("Эфир (симуляция: потери 30%, дубли 10%)") {
                        LabeledContent("Отправлено копий", value: "\(radio.copiesSent)")
                        LabeledContent("Дошло", value: radio.copiesArrived > 0
                                       ? "\(radio.copiesArrived) ✓"
                                       : "0 — все потерялись ✗")
                        LabeledContent("Байт в эфире", value: "\(radio.bytesOnAir)")
                        Text(radio.channelReport + " · seed \(radio.seed)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(RMDesign.surface1)

                    Section("Принято и развёрнуто") {
                        if radio.received != nil {
                            LabeledContent("Срочность", value: radio.receivedSeverity)
                            LabeledContent("Людей", value: "\(radio.received!.peopleCount)")
                            LabeledContent("Травма", value: radio.receivedInjury)
                            LabeledContent("Нужно", value: radio.receivedNeeds)
                            LabeledContent("Координаты", value: radio.receivedCoords)
                        } else {
                            Text("Ни одна копия не дошла — в реальности SOS "
                               + "повторяется, пока не придёт ACK.")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                    }
                    .listRowBackground(RMDesign.surface1)
                }

                if let json = model.rawJSON {
                    Section("Сырой JSON (отладка)") {
                        Text(json)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .listRowBackground(RMDesign.surface1)
                }
            }
            .rmScreenBackground()
            .navigationTitle("SOS → JSON")
        }
    }
}

#Preview {
    SOSExtractView()
}
