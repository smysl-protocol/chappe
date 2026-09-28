import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Фаза 2: одобрение инлайн в композере (модалки больше нет).
// Конвейер подменяется детерминированным (model.pipeline) — модель
// не нужна; кодек и матчер настоящие, байты настоящие.
// ============================================================================

@MainActor
struct ComposerApprovalTests {

    /// Детерминированная «семантика» из настоящего кодека.
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

    private func makeModel() -> HumanChatModel {
        let model = HumanChatModel()
        model.entries = []
        model.recalcDebounceMillis = 50
        return model
    }

    /// Подождать условие (модель крутит конвейер в Task).
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Двухтаповая печать: первый тап — поле подменяется развёрнутым
    /// текстом и появляется одобрение; второй тап — уходит в ленту.
    @Test func twoTapTypingFlow() async throws {
        let model = makeModel()
        let outcome = try semanticOutcome("be there soon in 10 minutes")
        model.pipeline = { _ in outcome }

        model.draft = "буду скоро минут через десять"
        let before = model.entries.count
        model.send()                       // первый тап
        await waitUntil { model.approval != nil }

        let approval = try #require(model.approval)
        #expect(approval.mode == .semantic)
        let rendered = try #require(approval.semantic?.rendered)
        #expect(model.draft == rendered, "поле = текст получателя")
        #expect(model.entries.count == before, "первый тап не отправляет")

        model.send()                       // второй тап (галочка)
        #expect(model.entries.count == before + 1)
        #expect(model.approval == nil)
        #expect(model.draft.isEmpty)
        let entry = try #require(model.entries.last)
        #expect(entry.text == rendered)
        #expect(entry.status?.contains("сжато") == true)
    }

    /// Правка одобренного: debounce → повторный конвейер → байты другие.
    @Test func editTriggersRecodeWithNewBytes() async throws {
        let model = makeModel()
        // конвейер зависит от текста — правка честно меняет байты
        model.pipeline = { [self] text in
            (try? semanticOutcome(text.contains("причал")
                ? "wait at the pier" : "be there soon in 10 minutes"))
            ?? .text(reason: "кодек недоступен", needsCard: false)
        }

        let source = "буду скоро минут через десять"
        model.draft = source
        model.send()
        await waitUntil { model.approval != nil }
        let firstBlob = try #require(model.approval?.semantic?.blob)
        // onChange программной подмены поля (эмуляция UI)
        model.draftEdited(old: source, new: model.draft)

        // ручная правка поля (как onChange из UI)
        let old = model.draft
        model.draft = "жди у причал"
        model.draftEdited(old: old, new: model.draft)
        #expect(model.isRecalculating, "бейдж «пересчитываю…»")

        await waitUntil {
            !model.isRecalculating && model.approval?.semantic != nil
        }
        let secondBlob = try #require(model.approval?.semantic?.blob)
        #expect(secondBlob != firstBlob, "байты обязаны перекодироваться")
    }

    /// Отправка ждёт последний пересчёт: тап по галочке во время
    /// debounce не шлёт старые байты, а ждёт новые.
    @Test func sendWaitsForPendingRecalc() async throws {
        let model = makeModel()
        model.pipeline = { [self] text in
            (try? semanticOutcome(text.contains("причал")
                ? "wait at the pier" : "be there soon in 10 minutes"))
            ?? .text(reason: "кодек недоступен", needsCard: false)
        }

        let source = "буду скоро минут через десять"
        model.draft = source
        model.send()
        await waitUntil { model.approval != nil }
        model.draftEdited(old: source, new: model.draft)   // onChange UI

        let old = model.draft
        model.draft = "жди у причал"
        model.draftEdited(old: old, new: model.draft)
        model.send()                       // тап во время пересчёта
        #expect(model.entries.isEmpty, "отправка обязана ждать пересчёт")

        await waitUntil { !model.entries.isEmpty }
        let entry = try #require(model.entries.last)
        // ушли НОВЫЕ байты: рендер соответствует «wait at the pier»
        let expected = try semanticOutcome("wait at the pier")
        guard case .semantic(let e) = expected else {
            Issue.record("фикстура не семантика"); return
        }
        #expect(entry.text == e.rendered)
        #expect(model.approval == nil)
    }

    /// TEXT-откат: текст поля не подменяется, отправка — текстом.
    @Test func textFallbackKeepsFieldAndSendsPlain() async throws {
        let model = makeModel()
        model.pipeline = { _ in .text(reason: "в тексте слишком много цифр",
                                      needsCard: true) }

        let source = "координаты 8.65 115.21 частота 923.125"
        model.draft = source
        model.send()
        await waitUntil { model.approval != nil }

        let approval = try #require(model.approval)
        #expect(approval.mode == .text)
        #expect(approval.semantic == nil)
        #expect(approval.reason == "в тексте слишком много цифр")
        #expect(model.draft == source, "TEXT-откат не подменяет текст")

        model.send()                       // второй тап — текстом
        let entry = try #require(model.entries.last)
        #expect(entry.text == source)
        #expect(entry.status?.hasPrefix("текст") == true)
    }

    /// Переключатель «смыслами/текстом» по тапу на бейдже: поле всегда
    /// показывает то, что уйдёт.
    @Test func badgeTogglesModeAndField() async throws {
        let model = makeModel()
        let outcome = try semanticOutcome("be there soon in 10 minutes")
        model.pipeline = { _ in outcome }

        let source = "буду скоро минут через десять"
        model.draft = source
        model.send()
        await waitUntil { model.approval != nil }
        let rendered = try #require(model.approval?.semantic?.rendered)

        model.toggleApprovalMode()         // смыслами → текстом
        #expect(model.approval?.mode == .text)
        #expect(model.draft == source, "текстом уходит исходник")

        model.toggleApprovalMode()         // текстом → смыслами
        #expect(model.approval?.mode == .semantic)
        #expect(model.draft == rendered)
    }
}
