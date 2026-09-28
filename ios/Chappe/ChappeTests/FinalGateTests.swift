import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Финальный гейт (полевой салат 28.07 прошёл старый gate и доехал до
// пузыря) + рендер слэш-вариантов словаря («ушёл/налево» → «ушёл»).
// ============================================================================

nonisolated struct FinalGateTests {

    @Test("Салатная фикстура → TEXT (ловит ≥3 разных латинских слова)")
    func saladGoesToText() {
        let reason = SemanticEncoder.finalGateReason(
            rendered: DictationFixtures.fieldSalad, units: [])
        #expect(reason != nil, "салат обязан уходить текстом")
        #expect(reason?.contains("непереведённые") == true, "\(reason ?? "")")
    }

    @Test("Здоровые финалы проходят: русский после петли и эталон с 1 латинским")
    func healthyFinalsPass() {
        let loopFinal = "Ну слушай, короче, мы выезжаем через 40 минут, "
            + "наверное, потому что сильный дождь затопил дорогу рядом с "
            + "рынком, поэтому поедем через мост. Возьми три бутылки воды "
            + "и хлеб — у нас всё закончилось."
        #expect(SemanticEncoder.finalGateReason(rendered: loopFinal,
                                                units: []) == nil)
        // одно латинское слово (rice) — не повод отправлять текстом
        let oneLatin = "Купить 5 бутылка вода и 2 килограмм rice у рынок "
            + "я дать деньги обратно вечером"
        #expect(SemanticEncoder.finalGateReason(rendered: oneLatin,
                                                units: []) == nil)
    }

    @Test("Имена (esc_name) не считаются латиницей")
    func namesAreNotLatin() {
        let rendered = "Рация проверить кто-нибудь слышать меня это Mark "
            + "от север пляж ждать ответ"
        let units: [RMCodec.Unit] = [.code(1), .name("Mark")]
        #expect(SemanticEncoder.finalGateReason(rendered: rendered,
                                                units: units) == nil)
    }

    @Test("Откат петли на машинном рендере с латиницей → TEXT, не салат в поле")
    func machineRenderFallbackGoesToText() {
        // машинная развёртка теста-1 (вход петли): leaving/heavy/…
        let machine = "Мы leaving в про 40 минут наверное потому что дождь "
            + "очень heavy мы встретиться у старый кафе upstairs у 7 взять "
            + "3 вода бутылка мой battery died вчера"
        #expect(SemanticEncoder.finalGateReason(rendered: machine,
                                                units: []) != nil)
    }

    @Test("Числа-времена: 730 в пивоте покрывает 7 и 30 (ферма, тест-1)")
    func timeNumbersNormalized() {
        // STT пишет «07:30», петля может слить в «730» — не потеря
        #expect(SemanticEncoder.lostNumbers(
            source: "встретимся в 07:30 у кафе",
            pivot: "meet at 730 at the cafe").isEmpty)
        // а настоящая потеря ловится
        #expect(SemanticEncoder.lostNumbers(
            source: "встретимся в 07:30",
            pivot: "meet at 7") == [30])
        // расширяется только пивот: 730 в исходнике требует 730
        #expect(SemanticEncoder.lostNumbers(
            source: "код 730", pivot: "code 7 30") == [730])
    }

    @Test("Порог словарности — только для текстов ≥12 токенов (падежи петли)")
    func dictionaryThresholdSkipsShortTexts() {
        // corpus03 с фермы: «воду/рынке/дам» мимо точного лексикона,
        // но текст короткий — не повод уходить текстом
        let short = "Купи питьевую воду и рис на рынке — 5 бутылок, "
                  + "2 килограмма. Денег дам вечером."
        #expect(SemanticEncoder.finalGateReason(rendered: short,
                                                units: []) == nil)
    }

    @Test("Рендер слэш-вариантов: первый вариант слова, не оба")
    func renderTakesFirstSlashVariant() throws {
        let codec = try #require(RMCodec.shared)
        #expect(RMCodec.firstVariant("ушёл/налево") == "ушёл")
        #expect(RMCodec.firstVariant("иди/еду домой") == "иди домой")
        #expect(RMCodec.firstVariant("нужны бинты/перевязка") == "нужны бинты")
        #expect(RMCodec.firstVariant("без слэша") == "без слэша")

        // сквозной: код 'left' рендерится «ушёл», не «ушёл/налево»
        let left = try #require(codec.byEn["left"])
        let rendered = codec.render([.code(left)])
        #expect(rendered == "Ушёл", "рендер: «\(rendered)»")
        // и ни один код словаря не рендерит слэш
        for entry in codec.entries.values where entry.ru != nil {
            let rendered = RMCodec.firstVariant(entry.ru!)
            #expect(!rendered.contains("/"),
                    "слэш пролез: \(entry.en) → «\(rendered)»")
        }
    }
}
