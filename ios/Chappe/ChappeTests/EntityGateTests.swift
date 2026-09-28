import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Гейт выдуманных сущностей (СРОЧНЫЙ бриф 31.07, случай «сын»).
// Худший класс ошибки мессенджера: пивот добавил факт, которого нет.
// Гейт — программный, как числовой: модель не может добавить то,
// чего не было. Плюс фикстура на протечку контекста между сообщениями.
// ============================================================================

nonisolated struct EntityGateTests {

    private var codec: RMCodec { RMCodec.shared! }

    // MARK: Фикстура брифа — дословно

    @Test("«сын» из воздуха не проходит гейт никогда")
    func inventedSonIsCaught() throws {
        let source = "задержусь так как неважно себя чувствую приболел по ходу"
        // Реальный сбой с устройства: выдуман сын, потеряно «задержусь»
        let badPivot = "i have health problems my NAME:Son is sick"
        let bad = SemanticEncoder.untracedEntities(source: source,
                                                   pivot: badPivot,
                                                   codec: codec)
        #expect(!bad.isEmpty, "гейт обязан поймать выдуманное")
        #expect(bad.contains { $0.lowercased().contains("son") },
                "именно «son»: \(bad)")
        // и голое «son» без NAME: ловится так же
        let bare = SemanticEncoder.untracedEntities(
            source: source, pivot: "i am sick my son is ill", codec: codec)
        #expect(bare.contains("son"), "голое son: \(bare)")
        #expect(SemanticEncoder.entityGateReason(source: source,
                                                 pivot: badPivot,
                                                 codec: codec) != nil)
    }

    @Test("честный пивот того же входа проходит")
    func honestPivotPasses() throws {
        let source = "задержусь так как неважно себя чувствую приболел по ходу"
        // задержусь → be late, приболел → sick: всё сводимо к входу
        let good = "i will be late i feel sick"
        let bad = SemanticEncoder.untracedEntities(source: source,
                                                   pivot: good,
                                                   codec: codec)
        #expect(bad.isEmpty, "ложное срабатывание: \(bad)")
    }

    @Test("обобщение ловится: «приболел» ≠ «проблемы со здоровьем»")
    func generalizationIsCaught() throws {
        let source = "задержусь приболел по ходу немного"
        let generalized = "i have problems with health"
        let bad = SemanticEncoder.untracedEntities(source: source,
                                                   pivot: generalized,
                                                   codec: codec)
        #expect(!bad.isEmpty, "обобщение обязано ловиться")
    }

    // MARK: Имена: настоящие проходят, чужие нет

    @Test("NAME: из входа проходит, чужое имя — нет")
    func namesTraceByTranslit() throws {
        let source = "передай марине что мы задержимся у моста"
        #expect(SemanticEncoder.untracedEntities(
            source: source,
            pivot: "tell NAME:Marina we will be late at the bridge",
            codec: codec).isEmpty)
        let bad = SemanticEncoder.untracedEntities(
            source: source,
            pivot: "tell NAME:Andrey we will be late",
            codec: codec)
        #expect(bad.contains { $0.lowercased().contains("andrey") },
                "чужое имя: \(bad)")
    }

    // MARK: Протечка контекста между сообщениями

    @Test("промпт пивота видит ровно одно сообщение")
    func pivotPromptSeesOnlyOneMessage() {
        // Три сообщения подряд «в одном чате»: в первом есть сын,
        // в третьем его нет. Промпт третьего не содержит ни слова
        // из первых двух — истории в промпте нет по построению.
        let first = "сын заболел встречайте нас в аэропорту мама волнуется"
        let second = "мы сели в самолёт вылетаем по расписанию"
        let third = "задержусь так как неважно себя чувствую приболел"
        var prompts: [String] = []
        for message in [first, second, third] {
            prompts.append(SemanticEncoder.pivotChunkPrompt(piece: message,
                                                            extra: ""))
        }
        #expect(prompts[2] == "RU: \(third)\nEN:")
        for word in ["сын", "аэропорт", "мама", "самолёт"] {
            #expect(!prompts[2].contains(word),
                    "протечка «\(word)» в промпт третьего сообщения")
        }
        // и системный шаблон статичен — истории нет и там
        #expect(!SemanticEncoder.chatPromptTemplate.contains("сын"))
    }

    @Test("гейт держит и цепочку: «сын» из первого не пролезает в третье")
    func chainedMessagesDoNotLeakEntities() throws {
        // Даже если модель (по какой-то причине) добавит «son» в пивот
        // третьего сообщения — гейт сверяет ТОЛЬКО с его собственным
        // входом и заворачивает
        let third = "задержусь так как неважно себя чувствую приболел"
        let leaked = "be late i am sick NAME:Son airport"
        let bad = SemanticEncoder.untracedEntities(source: third,
                                                   pivot: leaked,
                                                   codec: codec)
        #expect(bad.contains { $0.lowercased().contains("son") })
        #expect(bad.contains { $0.lowercased().contains("airport") })
    }

    // MARK: Короткая ru-колонка (лечение 05.08, live_corpus §5)
    // Ожидания извне (правило 4): примеры — дословно из промера §5,
    // записанного в отчёт ДО реализации лечения. Зеркало —
    // tools/dictation_farm/test_entity_gate_short_ru.py.

    @Test("короткое ru-слово входа лицензирует словарное слово пивота")
    func shortRuColumnTracesByExactWord() throws {
        // где → where, как → how, раз → times: стема ≥4 у них нет,
        // до лечения все три переворачивали сообщение в текст
        let healed: [(String, String)] = [
            ("А где здесь можно купить матэ?", "where to buy NAME:Mate here"),
            ("Это как? Просто интересно стало почему так", "how is this and why"),
            ("раз пять на байке ездил туда", "rode there 5 times"),
        ]
        for (ru, en) in healed {
            let bad = SemanticEncoder.untracedEntities(source: ru, pivot: en,
                                                       codec: codec)
            let shortFlags = bad.filter {
                ["where", "how", "times"].contains($0.lowercased())
            }
            #expect(shortFlags.isEmpty,
                    "короткая ru-колонка не прослежена на «\(ru)»: \(bad)")
        }
    }

    @Test("выдуманное слово с короткой ru-колонкой ловится по-прежнему")
    func inventedShortRuIsStillCaught() throws {
        // food → «еда»: во входе еды нет — флаг обязан остаться
        let bad = SemanticEncoder.untracedEntities(
            source: "задержусь приболел по ходу немного",
            pivot: "i am late and sick bring food", codec: codec)
        #expect(bad.contains("food"), "перелечили: food пропал из флагов")
        // точная сверка, не подстрока: «карта» содержит «как», но
        // целого слова «как» во входе нет
        let sub = SemanticEncoder.untracedEntities(
            source: "карта дорог у меня с собой лежит",
            pivot: "how is the road map", codec: codec)
        #expect(sub.contains("how"), "подстрока: «карта» лицензировала how")
    }

    // MARK: Здоровые пивоты словаря не зарубаются (антирегрессия)

    @Test("эталонные пары промпта проходят гейт")
    func promptExamplesPass() throws {
        let pairs: [(String, String)] = [
            ("ну я это самое буду минут через десять наверное",
             "be there soon in 10 minutes."),
            ("слушай генератор сломался бензина нет купи литров пять",
             "the generator is broken no petrol buy 5 liters"),
            ("передай марине что андрей уже в ростове",
             "tell NAME:Marina that NAME:Andrey is already in NAME:Rostov"),
            ("волны сегодня здоровые лодки не пойдут",
             "waves are big. boats do not go today."),
        ]
        for (ru, en) in pairs {
            let bad = SemanticEncoder.untracedEntities(source: ru, pivot: en,
                                                       codec: codec)
            #expect(bad.isEmpty, "ложное срабатывание на «\(ru)»: \(bad)")
        }
    }
}
