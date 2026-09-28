import Foundation
import Speech
import Testing
@testable import Chappe

// ============================================================================
// State-машина диктовки: idle → recording → processing → review → idle.
// Партиалы НЕ попадают в UI (только буфер), × возвращает композер как
// был, ■ отправляет буфер в конвейер (демо-чат) или в поле (Софи/шёпот).
// ============================================================================

@MainActor
struct DictationStateTests {

    // Замок А2 (полевой прогон 09.08, второй телефон): «включите в
    // Настройках», а строки там НЕТ — потому что отказ в первом
    // разрешении обрывал цепочку до запроса второго, а строка в
    // Настройках телефона рождается только самим запросом.
    // Блок 4 (10.08): ключи проверяются В СОБРАННОМ plist (правило
    // Info.plist: несуществующее имя настройки теряется молча, без
    // ошибки сборки). Без NSSpeechRecognitionUsageDescription запрос
    // распознавания не выстреливает и строки в Настройках телефона
    // не рождается — полевой тупик второго телефона (сборка 6).
    @Test("ключи диктовки живут в собранном Info.plist")
    func dictationUsageKeysAreInBuiltPlist() {
        let speech = Bundle.main.object(
            forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription")
            as? String
        let mic = Bundle.main.object(
            forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        #expect(speech?.isEmpty == false, Comment(rawValue:
                "NSSpeechRecognitionUsageDescription пропал из собранного "
                + "plist — speech-запрос молча перестанет выстреливать"))
        #expect(mic?.isEmpty == false)
    }

    @Test("оба запроса разрешений выполняются даже при отказе первого")
    func bothPermissionRequestsAlwaysFire() async {
        var micAsked = false
        let denied = await SpeechDictation.requestPermissions(
            requestSpeech: { .denied },
            requestMic: { micAsked = true; return true })
        #expect(micAsked, Comment(rawValue:
                "отказ в распознавании не смеет обрывать запрос "
                + "микрофона — иначе его строки в Настройках не будет"))
        #expect(!denied.speechOK && denied.micOK)

        var speechAsked = false
        let granted = await SpeechDictation.requestPermissions(
            requestSpeech: { speechAsked = true; return .authorized },
            requestMic: { true })
        #expect(speechAsked && granted.speechOK && granted.micOK)
    }

    // Замок на полевой тупик тел 2 (сборка 10, 10.08): support-гейт
    // стоял ПЕРВЫМ в start() и при «on-device ru недоступен» выходил
    // ДО запроса разрешений. Спираль замыкалась: строка разрешения в
    // Настройках рождается только самим запросом, а
    // supportsOnDeviceRecognition умеет врать false до выдачи
    // авторизации — запрос не фаерится → support не оживёт → запрос
    // не фаерится. Порядок гейтов: разрешения ВСЕГДА И ПЕРВЫМИ.
    @Test("разрешения запрашиваются даже при недоступном on-device")
    func permissionsFireEvenWhenUnsupported() async {
        var speechAsked = false
        var micAsked = false
        let outcome = await SpeechDictation.preflight(
            requestSpeech: { speechAsked = true; return .authorized },
            requestMic: { micAsked = true; return true },
            checkSupport: { false })
        #expect(speechAsked && micAsked, Comment(rawValue:
                "support-гейт не смеет обрывать запрос разрешений — "
                + "иначе строка в Настройках не родится никогда (тел 2)"))
        #expect(outcome == .unsupported)
    }

    // Замок на второй слой тупика тел 2 (сборка 11): .restricted =
    // запрет СИСТЕМЫ (Siri+Диктовка выключены) — запрос идёт без
    // диалога, строки в настройках приложения не рождается, и дверь
    // «в Настройки приложения» вела в пустоту. Подсказка обязана
    // вести к системным тумблерам, а не в настройки приложения.
    @Test("отказ речи: .restricted ведёт к системным тумблерам")
    func restrictedHintPointsAtSystemToggles() {
        #expect(SpeechDictation.speechDenialHint(.restricted)
                    .contains("Диктовку"))
        #expect(SpeechDictation.speechDenialHint(.restricted)
                    .contains("Siri"))
        #expect(!SpeechDictation.speechDenialHint(.denied)
                    .contains("Siri"), Comment(rawValue:
                "обычный отказ не смеет слать к Siri — там дверь в "
                + "Настройки приложения, где строка ЕСТЬ"))
    }

    @Test("порядок вердиктов preflight: отказ речи/микрофона/поддержки")
    func preflightVerdicts() async {
        let denied = await SpeechDictation.preflight(
            requestSpeech: { .denied },
            requestMic: { true },
            checkSupport: { true })
        #expect(denied == .speechDenied)

        let noMic = await SpeechDictation.preflight(
            requestSpeech: { .authorized },
            requestMic: { false },
            checkSupport: { true })
        #expect(noMic == .micDenied)

        let ready = await SpeechDictation.preflight(
            requestSpeech: { .authorized },
            requestMic: { true },
            checkSupport: { true })
        #expect(ready == .ready)
    }

    private nonisolated func semanticOutcome(_ pivot: String) throws
    -> SemanticEncoder.Outcome {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(fromPivot: pivot)
        let blob = try codec.encode(units)
        return .semantic(SemanticEncoder.Encoded(
            pivotRaw: pivot, pivot: pivot, units: units, blob: blob,
            rendered: codec.render(units)))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Во время записи распознавание молчит — поле не меняется")
    func recordingLeavesFieldUntouched() {
        let model = HumanChatModel()
        model.draft = "уже набрано"
        model.dictationDidStart()
        #expect(model.dictationState == .recording)
        // распознавателя во время записи нет вообще (файл-архитектура):
        // снапшот поля прежний, текста диктовки ноль
        #expect(model.draft == "уже набрано")
        #expect(!model.dictation.isRecognizing)
    }

    @Test("× — отмена: файл в мусор, композер как был")
    func cancelDiscardsBuffer() {
        let model = HumanChatModel()
        model.draft = "черновик"
        model.dictationDidStart()
        model.cancelDictation()

        #expect(model.dictationState == .idle)
        #expect(model.draft == "черновик")
        #expect(model.approval == nil, "конвейер не запускался")
    }

    // Тесты границ чанков переехали в DictationChunkingTests
    // (тихие точки, перекрытие 1 с, дедуп стыка).

    @Test("■ — буфер в конвейер: processing → review с бейджем")
    func stopRunsPipelineToReview() async throws {
        let model = HumanChatModel()
        model.entries = []
        let outcome = try semanticOutcome("be there soon in 10 minutes")
        model.pipeline = { _ in outcome }

        model.dictationDidStart()
        model.dictationDidFinish("буду скоро минут через десять")
        #expect(model.dictationState == .processing)

        await waitUntil { model.approval != nil }
        await waitUntil { model.dictationState == .idle }

        // review: развёрнутый текст в поле + готовое одобрение
        let rendered = try #require(model.approval?.semantic?.rendered)
        #expect(model.draft == rendered)
        #expect(model.dictationState == .idle)
        #expect(model.entries.isEmpty, "по ■ ничего не отправляется само")
    }

    @Test("■ в режиме шёпота: буфер в поле, конвейер не запускается")
    func whisperStopFillsFieldOnly() {
        let model = HumanChatModel()
        model.whisperMode = true
        model.draft = ""
        model.dictationDidStart()
        model.dictationDidFinish("как спросить про лодку")

        #expect(model.dictationState == .idle)
        #expect(model.draft == "как спросить про лодку")
        #expect(model.approval == nil, "шёпот не кодируется")
    }

    @Test("Пустой буфер по ■ — просто возврат в idle")
    func emptyBufferGoesIdle() {
        let model = HumanChatModel()
        model.draft = "было"
        model.dictationDidStart()
        model.dictationDidFinish("   ")
        #expect(model.dictationState == .idle)
        #expect(model.draft == "было")
        #expect(model.approval == nil)
    }

    @Test("Софи: по ■ буфер дописывается в поле, отправляет человек")
    func sophieStopAppendsToInput() {
        let model = SophieChatModel(preset: .comms)
        model.messages = []
        model.input = "и ещё"
        model.dictationDidStart()
        #expect(model.isDictating)
        #expect(model.input == "и ещё", "во время записи поле не трогаем")

        model.dictationDidFinish("про погоду")
        #expect(!model.isDictating)
        #expect(model.input == "и ещё про погоду")
        #expect(model.messages.isEmpty, "автоотправки нет")
    }

    @Test("Софи: × не трогает набранное")
    func sophieCancelKeepsInput() {
        let model = SophieChatModel(preset: .comms)
        model.input = "набрано"
        model.dictationDidStart()
        model.cancelDictation()
        #expect(!model.isDictating)
        #expect(model.input == "набрано")
    }

    @Test("Таймер индикатора: формат м:сс")
    func timerFormat() {
        #expect(DictationRecordingBar.timerText(0) == "0:00")
        #expect(DictationRecordingBar.timerText(9.4) == "0:09")
        #expect(DictationRecordingBar.timerText(75) == "1:15")
    }
}
