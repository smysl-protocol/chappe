import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Английские гейты (бриф 06.08: пре-гейт — блокер запуска). Ожидания
// извне: случаи NUS-замера 05.08, записанные в отчёте ДО починки.
// Зеркала python: test_pregate_en.py, test_missing_gate_en.py —
// расхождение зеркал = баг.
// ============================================================================

struct EnglishGatesTests {

    private var codec: RMCodec { RMCodec.shared! }

    // MARK: Язык входа

    @Test("язык входа: латиница → en, кириллица и смесь → ru")
    func dominantScript() {
        #expect(SemanticEncoder.dominantIsLatin("meet after lunch tomorrow"))
        #expect(!SemanticEncoder.dominantIsLatin("встречаемся у моста в семь"))
        #expect(!SemanticEncoder.dominantIsLatin("ok приду к семи с фонарём"))
    }

    // MARK: Пре-гейт (до починки все английские резались «вне лексикона»)

    @Test("английская координация проходит пре-гейт")
    func englishPassesPreGate() {
        for t in ["meet after lunch at the boat station tomorrow",
                  "i am not sure about night menu i know only about noon menu",
                  "on my way back if you get this call me"] {
            #expect(SemanticEncoder.preDetectReason(t, codec: codec) == nil,
                    "зарезано: \(t)")
        }
    }

    @Test("английский салат и техтекст режутся по-прежнему")
    func englishSaladStillGated() {
        #expect(SemanticEncoder.preDetectReason(
            "qwerty asdf zxcv uiop hjkl vbnm qazx wsxc",
            codec: codec) != nil)
        #expect(SemanticEncoder.preDetectReason(
            "build 4.2.1 sdk 33 apk 8080 http 443", codec: codec) != nil)
    }

    @Test("русский пре-гейт не изменился")
    func russianPreGateUnchanged() {
        #expect(SemanticEncoder.preDetectReason(
            "слушай генератор сломался бензина нет купи литров пять",
            codec: codec) == nil)
    }

    @Test("смешанный вход проходит без определения языка (союз колонок)")
    func mixedLanguagePassesPreGate() {
        // уточнение владельца 06.08: слово покрыто хоть одной колонкой
        for t in ["скинь tracking number завтра когда получишь",
                  "встречаемся в lobby отеля после ужина",
                  "забронируй table на четверых через приложение"] {
            #expect(SemanticEncoder.preDetectReason(t, codec: codec) == nil,
                    "смешанное зарезано: \(t)")
        }
    }

    // MARK: Финальный гейт — рендер языка получателя

    @Test("en-рендер: кириллица — чужое письмо, латиница — нет")
    func finalGateByLanguage() {
        // здоровый en-рендер (раньше хоронился как «непереведённые»)
        #expect(SemanticEncoder.finalGateReason(
            rendered: "what time is it going to rain now here",
            units: [], latinInput: true) == nil)
        // кириллица в en-рендере — не сложилось
        #expect(SemanticEncoder.finalGateReason(
            rendered: "what time дождь сейчас потом опять rain",
            units: [], latinInput: true) != nil)
        // ru: латиница ловится как раньше (дефолт параметра)
        #expect(SemanticEncoder.finalGateReason(
            rendered: "во сколько gonna rain menu сейчас дождь",
            units: []) != nil)
        #expect(SemanticEncoder.finalGateReason(
            rendered: "во сколько дождь сейчас пойдёт опять там",
            units: []) == nil)
    }

    // MARK: Английская трассировка гейта сущностей (очередь 06.08)

    @Test("сокращения, словоформы, апострофы, склейки — не выдумка")
    func abbreviationsAndInflectionsTrace() {
        let healed: [(String, String)] = [
            ("do u knw them or nt? may be ur frnds or classmates?",
             "do you know them or not maybe your friends or classmates ?"),
            ("so tmr wat time u can? i 1130 aft",
             "so tomorrow what time can you ?"),
            ("cant make it cos got class later",
             "i can't make it because i have class later"),
            ("how many ppl are coming later",
             "how many people are coming later ?"),
            ("did she say when they come to ask about it",
             "she says when they are coming to ask about it"),
            ("TIME IS VERY VALUEBLE,DON'T WASTE IT",
             "time is valuable dont waste it"),
        ]
        for (src, pivot) in healed {
            let bad = SemanticEncoder.untracedEntities(source: src,
                                                       pivot: pivot,
                                                       codec: codec)
            #expect(bad.isEmpty, "ложный флаг на «\(src.prefix(40))»: \(bad)")
        }
    }

    @Test("защита от перелечивания: несводимое остаётся флагом")
    func fabricationStillCaught() {
        // служебное «the» не лицензирует theory (правило ≤3 букв)
        #expect(SemanticEncoder.untracedEntities(
            source: "the boat is near the pier now today",
            pivot: "the boat is near the pier theory now",
            codec: codec).contains("theory"))
        // выдуманный food по-прежнему ловится
        #expect(SemanticEncoder.untracedEntities(
            source: "задержусь приболел по ходу немного",
            pivot: "i am late and sick bring food",
            codec: codec).contains("food"))
    }

    @Test("Singlish-частицы — не имена: понижаются до литерала")
    func particlesAreNotNames() throws {
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(fromPivot: "do you all reach liao bo ?")
        let hasFakeName = units.contains {
            if case .name(let n) = $0 {
                return PivotMatcher.singlishParticles.contains(n.lowercased())
            }
            return false
        }
        #expect(!hasFakeName, "частица стала именем: \(units)")
        // настоящее имя живо
        let named = matcher.units(fromPivot: "tell name_Marina we are late")
        #expect(named.contains {
            if case .name(let n) = $0 { return n == "Marina" }
            return false
        })
    }

    // MARK: Гейт пропажи — английские междометия

    @Test("междометия не «теряются», настоящая потеря ловится")
    func missingGateEnglishDroppables() {
        // ложные пропажи NUS (§4 п.2 отчёта): haha/hmmm/dont/alright
        let falsePositives: [(String, String)] = [
            ("Wah haha alright. You watched it?", "you watched it ?"),
            ("Hmmm... Green? So wat does it mean....",
             "green ? so what does it mean"),
            ("TIME IS VERY VALUEBLE,DONT WASTE IT",
             "time is very valuable waste it"),
            ("hahaha okay gonna sleep now goodnight",
             "okay sleep now goodnight"),
        ]
        for (src, rendered) in falsePositives {
            let got = SemanticEncoder.missingNounGateReason(
                source: src, units: [.lit(rendered)], rendered: rendered,
                codec: codec)
            #expect(got == nil, "ложная пропажа на «\(src)»: \(got ?? "")")
        }
        // настоящая потеря — класс sharp (#5 NUS)
        #expect(SemanticEncoder.missingNounGateReason(
            source: "Lol we leaving 4 sharp",
            units: [.lit("we leave at 4 .")], rendered: "we leave at 4 .",
            codec: codec)?.contains("sharp") == true)
        // русская пропажа не разлочена
        #expect(SemanticEncoder.missingNounGateReason(
            source: "собери рюкзак и спальник к вечеру",
            units: [.lit("собери рюкзак к вечеру")],
            rendered: "собери рюкзак к вечеру",
            codec: codec)?.contains("спальник") == true)
    }
}
