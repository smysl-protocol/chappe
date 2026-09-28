import Foundation
import Testing
@testable import Chappe

// ============================================================================
// П1 (28.07): ложный SOS из чата — «солнышко я соскучился» породил
// sos_active. Protected-слой недостижим из обычного чата тремя слоями:
// промпт (без protected), санитайзер (имена protected расщепляются),
// матчер (protected-диапазон запрещён в чат-контексте). SOS-вкладка
// не тронута — свой конвейер и подтверждение человека.
// + П3: короткие фразы ≤4 слов — всегда текстом, дословно.
// ============================================================================

nonisolated struct ChatProtectedGuardTests {

    private func hasProtected(_ units: [RMCodec.Unit],
                              _ codec: RMCodec) -> Bool {
        units.contains {
            if case .code(let code) = $0 {
                return codec.entries[code]?.layer == "protected"
            }
            return false
        }
    }

    @Test("Промпт чата не содержит protected-кодов и запрещает snake_case")
    func chatPromptHasNoProtectedCodes() {
        let prompt = SemanticEncoder.chatPromptTemplate
        for token in ["sos_active", "sos_cancel", "injury_", "state_",
                      "hazard_", "need_rescue", "severity_"] {
            #expect(!prompt.contains(token), "в промпте чата: \(token)")
        }
        #expect(prompt.contains("Never use snake_case"))
        // правило обращений (П4) — по умолчанию, не стиль
        #expect(prompt.contains("солнышко"))
    }

    @Test("Санитайзер: имя protected-кода расщепляется в слова")
    func sanitizerSplitsProtectedNames() throws {
        let codec = try #require(RMCodec.shared)
        #expect(SemanticEncoder.sanitize("sos_active help me need_rescue now",
                                         codec: codec)
                == "sos active help me need rescue now")
        // не-protected служебные živут (pm-маркер — слой grammar)
        let pm = SemanticEncoder.sanitize("at 5 pm", codec: codec)
        #expect(pm.contains("pm_marker"), "\(pm)")
    }

    @Test("Матчер в чат-контексте: «сигнал бедствия» → ноль protected")
    func matcherBlocksProtectedInChat() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        // пивот, каким он был бы у «сигнал бедствия помогите» при худшем
        // ответе модели: сырые protected-имена + обычные слова
        let pivot = SemanticEncoder.sanitize(
            "sos_active distress signal need_rescue help us please",
            codec: codec)
        let units = matcher.units(fromPivot: pivot, allowProtected: false)
        #expect(!hasProtected(units, codec), "protected просочился: \(units)")
        #expect(!units.isEmpty, "слова уходят кодами/литералами")

        // «солнышко я соскучился» — худший пивот из полевого инцидента
        let salad = SemanticEncoder.sanitize(
            "sos_active i am alone no connection i miss you", codec: codec)
        let saladUnits = matcher.units(fromPivot: salad, allowProtected: false)
        #expect(!hasProtected(saladUnits, codec))
    }

    @Test("SOS-путь и эталоны не тронуты: protected матчится при allowProtected")
    func sosPathStillMatchesProtected() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(fromPivot: "sos_active need_rescue")
        #expect(hasProtected(units, codec),
                "дефолт (эталоны/SOS) обязан матчить protected")
    }

    @Test("Тест-2: батарея уходит обычными кодами, число 15 живёт, gate доволен")
    func batteryPhraseGoesPlainCodes() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let source = "батарея у меня почти села процентов 15 осталось"
        // пивот чат-промпта (protected модели больше не показывают)
        let pivot = SemanticEncoder.sanitize(
            "my battery is almost dead 15 percent left", codec: codec)
        let units = matcher.units(fromPivot: pivot, allowProtected: false)

        #expect(!hasProtected(units, codec), "\(units)")
        let has = { (en: String) in units.contains {
            if case .code(let c) = $0 { return codec.entries[c]?.en == en }
            return false
        } }
        #expect(has("battery"), "батарея — кодом: \(units)")
        #expect(has("percent"), "процент — кодом: \(units)")
        #expect(units.contains(.num(15)), "число 15 живёт")

        // gate доволен: числа целы, литералов мало
        let blob = try codec.encode(units)
        #expect(SemanticEncoder.gateReason(source: source, pivot: pivot,
                                           units: units, blob: blob) == nil)
        #expect(SemanticEncoder.finalGateReason(rendered: codec.render(units),
                                                units: units) == nil)
    }

    // MARK: П3 — короткие фразы

    @Test("≤4 слов — всегда текстом, дословно, до модели")
    func shortPhrasesGoAsText() async {
        for phrase in ["дальше медленно", "ок понял", "да",
                       "жди у старого кафе"] {
            let outcome = await SemanticEncoder.prepare(russian: phrase)
            guard case .text(let reason, let needsCard) = outcome else {
                Issue.record("«\(phrase)» ушло семантикой")
                continue
            }
            #expect(reason.contains("короткое"), "\(phrase): \(reason)")
            #expect(!needsCard, "тихий текст, без карточки")
        }
        // 5 слов — уже пробует семантику (в тестах модель недоступна →
        // честный откат «модель недоступна», не «короткое»)
        let outcome = await SemanticEncoder.prepare(
            russian: "мы будем ждать тебя завтра")
        if case .text(let reason, _) = outcome {
            #expect(!reason.contains("короткое"), "\(reason)")
        }
    }
}
