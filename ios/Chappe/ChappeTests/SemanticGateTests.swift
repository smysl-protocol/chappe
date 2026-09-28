//
//  SemanticGateTests.swift
//  RMTests
//
//  Три линии обороны семантического конвейера: пред-детект (без модели),
//  gate качества после пивота, сохранность обычных диктовок.
//

import Foundation
import Testing
@testable import Chappe

/// Ждать СОБЫТИЕ, а не время (ревизия параллелизма 06.08). Фиксированные
/// sleep'ы в тестах вью-модели давали флейк: под нагрузкой полного
/// прогона конвейер не успевал за отведённые миллисекунды. Опрос каждые
/// 10 мс до 5 с; не дождались — честный провал с текстом, а не молчание.
@MainActor
func until(_ label: String = "условие",
           timeout: Duration = .seconds(60),
           _ condition: () -> Bool) async throws {
    // 60 с, не 20 (13.08 — тот же класс отказа, что 08.08 при подъёме
    // 5 → 20): в общем параллельном прогоне LLM-смоуки голодят главный
    // актор; рост сюиты сместил раскладку по клонам, и ожидающие тесты
    // краснели по одному-два за прогон РАЗНЫМИ жертвами (пять прогонов
    // 13.08), в одиночку проходя за доли секунды.
    // Ожидание по УСЛОВИЮ: здоровый прогон быстрее ни на миг не станет,
    // сломанный — честно упадёт по таймауту.
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("не дождались: \(label)")
    throw CancellationError()
}

/// Текст со скрина полевого теста (технический, про передачу данных).
let screenMessageForTests = """
Если речь идет о передаче данных (например, через Meshtastic), то \
ограничения обычно считаются в байтах, а не в символах. Поэтому \
русскоязычный текст помещается примерно в два раза меньше по количеству \
символов, чем английский, при одинаковом размере пакета.
"""

/// Расширенный вариант (~1276 Б как в карточке): те же числа, что модель
/// превратила в «пивот-салат» — 20, 18, 200, 180, 190, 909, 220.
let screenMessageLongForTests = screenMessageForTests + """
 Например, если заголовок занимает 20 bytes, то на 18 смысловых концептов \
остаётся около 20 байт служебных данных. Пакет размером 200 bytes несёт \
примерно 180 полезных байт, а при лимите 190 концепты приходится резать. \
Текст длиной 909 символов сжимается к 220 байтам в лучшем случае, и это \
уже за пределами одного пакета LoRa при любом раскладе.
"""

struct SemanticGateTests {

    /// Сообщение со скрина: пред-детект отправляет текстом, модель
    /// не дёргается (слова вне словаря смыслов).
    @Test func screenMessageGoesText() throws {
        let codec = try #require(RMCodec.shared)
        // Ф1 v1.1: при 100% ru-покрытии короткий скрин-текст прегейт
        // уже не отличает лексически (39% vs порог 37%) — его держит
        // финальный гейт. Числовой вариант прегейт ловит всегда.
        let long = SemanticEncoder.preDetectReason(screenMessageLongForTests, codec: codec)
        #expect(long != nil, "числовой техтекст обязан уйти текстом")
    }

    /// Обычная речь пред-детект проходит.
    @Test func ordinarySpeechPassesPreDetect() throws {
        let codec = try #require(RMCodec.shared)
        let corpus = try #require(Bundle.main.url(forResource: "dictation_corpus",
                                                  withExtension: "jsonl"))
        let lines = try String(contentsOf: corpus, encoding: .utf8)
            .split(separator: "\n").filter { !$0.isEmpty }
        for line in lines {
            let item = try JSONSerialization.jsonObject(with: Data(line.utf8))
                as! [String: Any]
            let ru = item["ru_dictation"] as! String
            #expect(SemanticEncoder.preDetectReason(ru, codec: codec) == nil,
                    "диктовка не должна отсекаться: «\(ru.prefix(60))…»")
        }
    }

    /// Чат-диктовки корпуса остаются семантикой и после gate.
    @Test func dictationsStaySemanticThroughGate() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let corpus = try #require(Bundle.main.url(forResource: "dictation_corpus",
                                                  withExtension: "jsonl"))
        let lines = try String(contentsOf: corpus, encoding: .utf8)
            .split(separator: "\n").filter { !$0.isEmpty }
        for line in lines {
            let item = try JSONSerialization.jsonObject(with: Data(line.utf8))
                as! [String: Any]
            let ru = item["ru_dictation"] as! String
            let rawPivot = item["pivot_ref"] as! String
            // SOS-эталоны (с protected-кодами) идут SOS-путём, не чатом:
            // П1 чат-санитайзер их расщепляет — это желаемое поведение
            let hasProtected = rawPivot.split(separator: " ").contains {
                let t = String($0)
                guard t.contains("_"), let code = codec.byEn[t] else { return false }
                return codec.entries[code]?.layer == "protected"
            }
            if hasProtected { continue }
            let pivot = SemanticEncoder.sanitize(rawPivot, codec: codec)
            let units = matcher.units(fromPivot: pivot, allowProtected: false)
            let blob = try codec.encode(units)
            let reason = SemanticEncoder.gateReason(source: ru, pivot: pivot,
                                                    units: units, blob: blob)
            #expect(reason == nil,
                    "gate забраковал эталон «\(pivot.prefix(50))…»: \(reason ?? "")")
        }
    }

    /// Пивот потерял число 20 — gate ловит.
    @Test func gateCatchesLostNumber() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let source = "купи 5 бутылок воды и 20 литров бензина на заправке"
        let badPivot = "buy 5 bottles of water and petrol"   // 20 потеряно
        let units = matcher.units(fromPivot: badPivot)
        let blob = try codec.encode(units)
        let reason = SemanticEncoder.gateReason(source: source, pivot: badPivot,
                                                units: units, blob: blob)
        #expect(reason?.contains("20") == true, "причина: \(reason ?? "nil")")
    }

    /// Пивот-огрызок (сильная суммаризация) — gate ловит по полноте.
    @Test func gateCatchesOverSummarized() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let source = "мы вчера дошли до водопада но тропа после ливня размыта "
                   + "обратно через реку идти опасно вода поднялась поэтому мы "
                   + "решили заночевать наверху у смотровой площадки"
        let badPivot = "all good"
        let units = matcher.units(fromPivot: badPivot)
        let blob = try codec.encode(units)
        let reason = SemanticEncoder.gateReason(source: source, pivot: badPivot,
                                                units: units, blob: blob)
        #expect(reason?.contains("короткий") == true, "причина: \(reason ?? "nil")")
    }

    /// Literal-доминирование — gate ловит.
    @Test func gateCatchesLiteralDominance() throws {
        let codec = try #require(RMCodec.shared)
        let units: [RMCodec.Unit] = [
            .lit("completely uncovered gibberish that dictionary cannot map at all"),
        ]
        let blob = try codec.encode(units)
        let reason = SemanticEncoder.gateReason(
            source: "какой-то исходник с четырьмя словами тут",
            pivot: "completely uncovered gibberish that dictionary cannot map at all",
            units: units, blob: blob)
        #expect(reason?.contains("непокрытый") == true, "причина: \(reason ?? "nil")")
    }

    /// Чанкование: предложения не теряются и не сливаются.
    @Test func chunkingKeepsSentences() {
        let text = "Первое предложение. Второе предложение! Третье? "
                 + String(repeating: "Очень длинное четвёртое предложение про горы и реки. ", count: 6)
        let sentences = SemanticEncoder.sentences(text)
        #expect(sentences.count == 9, "предложений: \(sentences.count)")
        let chunks = SemanticEncoder.chunks(text)
        #expect(chunks.count > 1)
        // все предложения дословно присутствуют в склейке чанков
        let joined = chunks.joined(separator: " ")
        for s in sentences {
            #expect(joined.contains(s), "потеряно: \(s)")
        }
    }
}

/// Фикстура 28.07 (п.3): имена и служебные формы не должны ронять
/// прегейт — «Марина…Андрея» обязана дойти до модели.
struct PreGateFixtureTests {
    static let fixture = "Марина с нами не поедет, у неё температура. "
        + "Ты сможешь забрать Андрея или лучше ему добираться самому? "
        + "Ответь до восьми, потому что дальше связи не будет."

    @Test func namesAndFunctionFormsPassPreGate() throws {
        let codec = try #require(RMCodec.shared)
        #expect(SemanticEncoder.preDetectReason(Self.fixture,
                                                codec: codec) == nil,
                "фикстура — обычная речь, прегейт обязан пропустить")
        // «Андрея» — заглавная в середине предложения — кандидат в имена
        let names = SemanticEncoder.probableNameWords(Self.fixture)
        #expect(names.contains("андрея"))
        // первое слово предложения именем не считается
        #expect(!names.contains("марина"))
        #expect(!names.contains("ответь"))
    }
}

/// П.1 предзаморозки: отмена договорённости — ЧАТ-смысл, кодируется
/// free-кодами при закрытом protected (отбой тревоги не задет).
struct ChatCancelTests {
    @Test func cancellationEncodesInChatContext() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let pivots = [
            "listen the old cafe is cancelled we are not going there",
            "the meeting is called off we are fine",
        ]
        for pivot in pivots {
            let units = matcher.units(fromPivot: pivot, allowProtected: false)
            // отмена дошла кодом, не литералом
            let hasCancel = units.contains { unit in
                if case .code(let code) = unit {
                    let en = codec.entries[code]?.en
                    return en == "cancel" || en == "call off"
                }
                return false
            }
            #expect(hasCancel, Comment(rawValue: "нет кода отмены: \(pivot)"))
            // и ни одного литерала со словом отмены
            let litWithCancel = units.contains { unit in
                if case .lit(let s) = unit { return s.contains("cancel") }
                return false
            }
            #expect(!litWithCancel)
            // protected по-прежнему недостижим
            let hasProtected = units.contains { unit in
                if case .code(let code) = unit {
                    return codec.entries[code]?.layer == "protected"
                }
                return false
            }
            #expect(!hasProtected, "protected в чат-контексте — нарушение П1")
        }
    }
}

/// Поправка на имена в прегейте. С Ф1 v1.1 (ru 100%) лексический
/// прегейт для короткого скрин-текста на грани (39% против порога
/// 37%) — его соль с именами ловит финальный гейт (fieldSalad в
/// FinalGateTests). Здесь фиксируем неразмываемое: ЦИФРОВАЯ проверка
/// (>15% цифр) именами не разбавляется.
struct PreGateNameCorrectionTests {
    @Test func numericSaladWithNamesStaysText() throws {
        let codec = try #require(RMCodec.shared)
        let salted = screenMessageLongForTests
            + " Перешли это Марине, Андрею и Виктору Петровичу."
        #expect(SemanticEncoder.preDetectReason(salted, codec: codec) != nil,
                "имена не должны протаскивать числовой техтекст в семантику")
    }
}

/// Ферма п.0: промпт пивота лежит под версией
/// (tools/semdict/pivot_prompt_chat_v2.txt; v2 = правило 9, запрет
/// новых сущностей, 31.07) — Swift-литерал обязан совпадать с файлом
/// байт в байт. Правка промпта = новый версионный файл + прогон корпуса.
struct PivotPromptVersionTests {
    @Test func promptMatchesVersionedFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent(
            "tools/semdict/pivot_prompt_chat_v2.txt"), encoding: .utf8)
        #expect(SemanticEncoder.chatPromptTemplate + "\n" == file,
                "промпт разошёлся с версионированным файлом")
    }
}

/// П.3 пост-фермы: потерянное отрицание не теряет факт — ИНВЕРТИРУЕТ
/// его. Рендер обязан нести и отрицание, и отрицаемое действие.
struct NegationGateTests {
    @Test func lostNegationIsCaught() {
        // «Я бы никогда на это не пошёл» → рендер растерял действие
        #expect(SemanticEncoder.negationGateReason(
            source: "Я бы никогда на это не пошёл",
            rendered: "Я никогда то") != nil)
        // «хлеб не бери» → инверсия «хлеб брать» — ловится
        #expect(SemanticEncoder.negationGateReason(
            source: "хлеб не бери",
            rendered: "хлеб взять") != nil)
        // «туда не идём» → «мы идти там» — отрицание пропало
        #expect(SemanticEncoder.negationGateReason(
            source: "туда не идём",
            rendered: "мы идти там") != nil)
    }

    @Test func intactNegationsPass() {
        #expect(SemanticEncoder.negationGateReason(
            source: "Я бы никогда на это не пошёл",
            rendered: "Я никогда не пойти на то") == nil)
        #expect(SemanticEncoder.negationGateReason(
            source: "хлеб не бери",
            rendered: "хлеб не брать я купить 3 буханки") == nil)
        #expect(SemanticEncoder.negationGateReason(
            source: "туда не идём",
            rendered: "мы не идти там") == nil)
        // отмена — собственный маркер
        #expect(SemanticEncoder.negationGateReason(
            source: "отбой по кафе",
            rendered: "старый кафе отмена") == nil)
        #expect(SemanticEncoder.negationGateReason(
            source: "отбой по кафе",
            rendered: "старый кафе встреча") != nil)
        // текст без отрицаний гейт не трогает
        #expect(SemanticEncoder.negationGateReason(
            source: "буду через 20 минут у пирса",
            rendered: "быть там скоро в 20 минут пирс") == nil)
    }
}

/// Б2 (29.07): правка распознанного руками авторитетна — уходит
/// дословно текстом, если семантический рендер не совпал посимвольно.
struct ManualEditAuthorityTests {
    @Test @MainActor func editedTextGoesVerbatim() async throws {
        let model = HumanChatModel()
        model.recalcDebounceMillis = 10
        model.pipeline = { _ in
            .semantic(SemanticEncoder.Encoded(
                pivotRaw: "p", pivot: "p", units: [.num(2)], blob: [1, 2],
                rendered: "Я не нужно много вода 2 бутылка хватит"))
        }
        // диктовка → одобрение
        model.dictationDidStart()
        model.dictationDidFinish("мне не надо много воды двух бутылок хватит")
        // Ревизия параллелизма 06.08: ждём СОБЫТИЕ (одобрение готово), а
        // не фиксированные 300 мс. Под нагрузкой полного прогона сон
        // истекал раньше конвейера, «программный» флаг подмены доставался
        // не тому вызову draftEdited — тест краснел на ровном месте.
        try await until("одобрение готово") {
            model.approval != nil && !model.isEncoding
        }
        // вьюха съедает programmatic-флаг подмены рендера
        model.draftEdited(old: "", new: model.draft)
        // человек правит текст руками
        model.draft = "мне не нужно много воды, достаточно две бутылки"
        model.draftEdited(old: "х", new: model.draft)
        try await until("пересчёт завершён") {
            !model.isRecalculating && model.approval != nil
        }
        let a = try #require(model.approval)
        #expect(a.mode == .text, "правка руками — только текстом")
        #expect(a.reason == "точно как написано")
        model.cancelApproval()
    }

    @Test @MainActor func matchingRenderMayStaySemantic() async throws {
        let model = HumanChatModel()
        model.recalcDebounceMillis = 10
        let exact = "Взять 2 бутылки воды."
        model.pipeline = { _ in
            .semantic(SemanticEncoder.Encoded(
                pivotRaw: "p", pivot: "p", units: [.num(2)], blob: [1],
                rendered: exact))
        }
        model.dictationDidStart()
        model.dictationDidFinish("возьми две бутылки воды")
        try await until("одобрение готово") {
            model.approval != nil && !model.isEncoding
        }
        model.draft = exact
        model.draftEdited(old: "х", new: exact)
        try await until("пересчёт завершён") {
            !model.isRecalculating && model.approval != nil
        }
        let a = try #require(model.approval)
        #expect(a.mode == .semantic, "посимвольное совпадение — можно семантикой")
        model.cancelApproval()
    }
}
