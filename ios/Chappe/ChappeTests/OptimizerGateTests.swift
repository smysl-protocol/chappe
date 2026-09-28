import Testing
import Foundation
@testable import Chappe

// ============================================================================
// Замок оптимизатора текста (часть 2 брифа 08.08).
//
// Исходники фикстур — ЖИВОЙ корпус, а не сочинённые примеры:
// полевого корпуса (приватен, см. publication manifest), номера строк (seq)
// указаны у каждой. «Порча» — то, как ошибается модель при сокращении:
// теряет отрицание, роняет условие, округляет число, выкидывает
// приблизительность, забывает адресата.
//
// Красная фикстура здесь — пара (исходник, испорченное переписывание),
// которую гейт ОБЯЗАН отвергнуть. Зелёная — честное сокращение, которое
// гейт обязан пропустить, иначе оптимизатор будет молчать всегда и
// функция окажется бесполезной.
// ============================================================================

struct OptimizerGateTests {

    // MARK: Красные — гейт обязан отвергнуть

    @Test func lostNegationIsRejected() {
        // корпус seq 287
        let src = "вам уже во всех чатах ответили, не надо спамить"
        let bad = "вам уже ответили, надо писать в один чат"
        let reason = OptimizerGate.rejectionReason(source: src, rewritten: bad)
        #expect(reason?.contains("отрицание") == true, "\(reason ?? "nil")")
    }

    @Test func lostConditionIsRejected() {
        // корпус seq 58
        let src = "А если не доедут, буду виновата"
        let bad = "Они не доедут, буду виновата"
        let reason = OptimizerGate.rejectionReason(source: src, rewritten: bad)
        #expect(reason?.contains("условие") == true, "\(reason ?? "nil")")
    }

    @Test func changedNumberIsRejected() {
        // корпус seq 199 (сумма в сообщении)
        let src = "Цена сильно зависит от лодки, 855 очень мало"
        let bad = "Цена зависит от лодки, 850 мало"
        let reason = OptimizerGate.rejectionReason(source: src, rewritten: bad)
        #expect(reason?.contains("число") == true, "\(reason ?? "nil")")
    }

    @Test func lostApproximationIsRejected() {
        // корпус seq 247 — «наверное» превращается в утверждение
        let src = "Она там и есть, наверное, своими глазами ещё не видел"
        let bad = "Она там, своими глазами не видел"
        let reason = OptimizerGate.rejectionReason(source: src, rewritten: bad)
        #expect(reason?.contains("приблизительность") == true,
                "\(reason ?? "nil")")
    }

    @Test func lostAddresseeIsRejected() {
        // корпус seq 287: адресат обращения пропал
        let src = "@user11, вам уже во всех чатах ответили, не надо спамить"
        let bad = "Вам уже ответили, не надо спамить"
        let reason = OptimizerGate.rejectionReason(source: src, rewritten: bad)
        #expect(reason?.contains("имя") == true, "\(reason ?? "nil")")
    }

    @Test func lostTimeIsRejected() {
        let src = "выезжаем завтра в 6:30 от виллы"
        let bad = "выезжаем от виллы рано"
        let reason = OptimizerGate.rejectionReason(source: src, rewritten: bad)
        #expect(reason?.contains("время") == true, "\(reason ?? "nil")")
    }

    @Test func lostPlaceIsRejected() {
        // корпус seq 239 — аэропорт превращается в «там»
        let src = "Сбор, который платишь в аэропорту, не покрывает Пениду"
        let bad = "Сбор, который платишь там, не покрывает Пениду"
        let reason = OptimizerGate.rejectionReason(source: src, rewritten: bad)
        #expect(reason?.contains("место") == true, "\(reason ?? "nil")")
    }

    @Test func inventedNegationIsRejected() {
        // модель добавила ограничение, которого человек не писал
        let src = "дорога сложная, ехать долго"
        let bad = "дорога сложная, ехать нельзя"
        let reason = OptimizerGate.rejectionReason(source: src, rewritten: bad)
        #expect(reason?.contains("отрицание") == true, "\(reason ?? "nil")")
    }

    // MARK: Зелёные — гейт обязан пропустить

    @Test func honestShorteningPasses() {
        // корпус seq 53: вежливость и вода уходят, факты целы
        let src = "без разницы. если только отталкиваться откуда вы едете "
                + "и куда после этого"
        let good = "без разницы, если отталкиваться откуда едете и куда"
        #expect(OptimizerGate.rejectionReason(source: src,
                                              rewritten: good) == nil)
    }

    @Test func wordNumberNormalisationPasses() {
        // «семь» → «7» — та же величина, гейт ругаться не должен
        let src = "встречаемся у моста в семь утра"
        let good = "встреча у моста в 7 утра"
        #expect(OptimizerGate.rejectionReason(source: src,
                                              rewritten: good) == nil)
    }

    @Test func caseFormsOfPlacePass() {
        // падеж места меняется при сокращении — это не потеря
        let src = "все собираются на пляже у отеля"
        let good = "сбор на пляж у отель"
        #expect(OptimizerGate.rejectionReason(source: src,
                                              rewritten: good) == nil)
    }

    // MARK: Разбор классов — ожидания извне, не из кода

    @Test func classExtractorsMatchHandCounts() {
        #expect(OptimizerGate.negations("не надо спамить") == ["не"])
        #expect(OptimizerGate.conditions("а если не доедут") == ["если"])
        #expect(OptimizerGate.numbers("855 и пару тысяч") == ["855", "2", "1000"])
        #expect(OptimizerGate.approximations("вроде бы очень мало") == ["вроде"])
        #expect(OptimizerGate.times("завтра в 6:30").contains("6:30"))
        #expect(OptimizerGate.places("в аэропорту и на пляже")
                == ["аэропорт", "пляж"])
        #expect(OptimizerGate.names("@user11, вам ответили")
                .contains("@user11"))
    }
}
