import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Нормализация форм в лексическом пре-гейте (решение владельца 03.08,
// docs/reports/pregate_analysis_2026-08-03.md).
//
// Разбор 383 лексических отказов синтетического стресса: 88% —
// ASR-опечатки СЛОВАРНЫХ слов («мсот», «вдоа», «жжжди»). Токен, не
// прошедший лексикон с первого раза, нормализуется ДО подсчёта доли
// «вне лексикона»:
//   1) повторы букв (3 и более одинаковых подряд → одна),
//      лексикон пробуется снова;
//   2) если не помогло — расстояние Дамерау-Левенштейна 1 до слова
//      лексикона; токены длиной ≤3 расстоянием НЕ лечатся (ложные
//      срабатывания на предлогах).
// Токен, прошедший нормализацию, считается В лексиконе.
//
// ЦИФРОВОЕ правило (>15% цифр) НЕ ТРОНУТО — решение владельца, ждёт
// полевого корпуса. Стоп-лист филлеров НЕ добавлен (отдельная мера,
// владелец её не заказывал).
//
// Зеркало python — pre_detect в tools/dictation_farm/farm_text.py,
// тест — tools/dictation_farm/test_pregate_norm.py (расхождение
// логики зеркал = баг).
// ============================================================================

struct PreGateNormalizationTests {

    /// Схлопывание повторов: 3+ одинаковых буквы подряд → одна.
    @Test func collapseRepeatsWorks() {
        #expect(SemanticEncoder.collapseRepeats("жжжди") == "жди")
        #expect(SemanticEncoder.collapseRepeats("утррро") == "утро")
        #expect(SemanticEncoder.collapseRepeats("рынооооок") == "рынок")
        // двойная буква — законная орфография, не трогаем
        #expect(SemanticEncoder.collapseRepeats("аллея") == "аллея")
        #expect(SemanticEncoder.collapseRepeats("мост") == "мост")
    }

    /// Расстояние 1 (перестановка соседних, замена, пропуск, вставка)
    /// до словарного слова лечит ASR-опечатку.
    @Test func distanceOneHealsTypos() throws {
        _ = try #require(RMCodec.shared)   // лексикон строится из словаря
        #expect(SemanticEncoder.normalizedInLexicon("мсот"))   // → мост
        #expect(SemanticEncoder.normalizedInLexicon("вдоа"))   // → вода
        #expect(SemanticEncoder.normalizedInLexicon("ырнок"))  // → рынок
        #expect(SemanticEncoder.normalizedInLexicon("лодак"))  // → лодка
        // глубокое искажение (расстояние ≥2) не лечится — честный отказ
        #expect(!SemanticEncoder.normalizedInLexicon("еербг"))
    }

    /// Токены ≤3 букв расстоянием не лечатся: «мст» в одной правке от
    /// «мост», но на коротких токенах расстояние 1 даёт ложные
    /// совпадения с предлогами — выключено по отчёту 03.08.
    @Test func shortTokensSkipDistance() throws {
        _ = try #require(RMCodec.shared)
        #expect(!SemanticEncoder.normalizedInLexicon("мст"))
    }

    /// Сообщение из одних ASR-опечаток словарных слов проходит пре-гейт.
    @Test func typoMessagePassesPreGate() throws {
        let codec = try #require(RMCodec.shared)
        #expect(SemanticEncoder.preDetectReason("мсот вдоа жжжди",
                                                codec: codec) == nil)
        // 4 содержательных слова — работает порог, а не guard «<4 слов»;
        // без нормализации было бы 100% вне лексикона → отказ
        #expect(SemanticEncoder.preDetectReason("мсот вдоа ырнок утррро",
                                                codec: codec) == nil,
                "все четыре опечатки лечатся нормализацией")
    }

    /// Честный отказ остаётся отказом: URL нормализацией не лечится.
    @Test func urlStillRefused() throws {
        let codec = try #require(RMCodec.shared)
        #expect(SemanticEncoder.preDetectReason(
            "https://example.com/x?y=1#z жди", codec: codec) != nil,
            "URL законно уходит текстом (отчёт 03.08: 13 честных отказов)")
    }

    /// ЗАМОК: цифровое правило (>15% цифр) не задето — решение
    /// владельца, ждёт полевого корпуса. «встретимся в 12:05»
    /// по-прежнему режется — это ТЕКУЩЕЕ поведение, менять его можно
    /// только по полевому замеру, не этой задачей.
    @Test func digitRuleUntouched() throws {
        let codec = try #require(RMCodec.shared)
        let reason = SemanticEncoder.preDetectReason("встретимся в 12:05",
                                                     codec: codec)
        #expect(reason == "в тексте слишком много цифр",
                Comment(rawValue: "цифровое правило изменилось: \(reason ?? "nil")"))
    }
}
