import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Фаза 1: словный чанкер для диктовок без пунктуации.
// Пивот длинного STT-текста падал (один чанк на 50+ слов → модель
// суммаризует → gate шлёт в TEXT); теперь режем по ~15 слов,
// границы — перед маркерами начала мысли.
// ============================================================================

nonisolated struct WordChunkerTests {

    /// Чанки фикстуры: 10–20 слов каждый, ни одно слово не потеряно.
    @Test func fixtureChunksAreBounded() {
        let chunks = SemanticEncoder.wordChunks(DictationFixtures.longTrip)
        #expect(chunks.count >= 2, "51 слово обязано резаться: \(chunks.count)")
        for chunk in chunks {
            let n = SemanticEncoder.wordCount(chunk)
            #expect((10...20).contains(n), "чанк вне 10–20 слов (\(n)): \(chunk)")
        }
        // склейка чанков даёт исходный текст слово в слово
        let glued = chunks.joined(separator: " ")
        #expect(glued == DictationFixtures.longTrip)
    }

    /// Граница — перед маркером начала мысли, если он есть в окне ±4.
    @Test func cutsBeforeThoughtMarker() {
        // 15-е слово от начала (индекс 15) — не маркер, но «вот» на 14-м:
        // 22 слова, цель 15, окно 11–19, «вот» — индекс 13
        let text = "мы едем по дороге уже долго ищем место для ночлега около "
                 + "реки страшно вот думаем ставить палатку или вернуться "
                 + "обратно домой"
        let chunks = SemanticEncoder.wordChunks(text)
        #expect(chunks.count == 2)
        let second = chunks[1]
        #expect(second.hasPrefix("вот "), "резать перед маркером: «\(second)»")
    }

    /// Маркера в окне нет — режем ровно по цели (15 слов).
    @Test func cutsAtTargetWithoutMarker() {
        let words = Array(repeating: "слово", count: 30).joined(separator: " ")
        let chunks = SemanticEncoder.wordChunks(words)
        #expect(chunks.count == 2)
        #expect(SemanticEncoder.wordCount(chunks[0]) == 15)
        #expect(SemanticEncoder.wordCount(chunks[1]) == 15)
    }

    /// Короткий текст (≤20 слов) — один чанк, без резки.
    @Test func shortTextIsSingleChunk() {
        let text = "генератор сломался бензина нет купи пять литров"
        #expect(SemanticEncoder.wordChunks(text) == [text])
    }

    /// Текст с пунктуацией: короткие предложения группируются как раньше,
    /// предложение длиннее 25 слов дорезается словным чанкером.
    @Test func longSentenceInsidePunctuatedTextIsRechunked() {
        let short = "Мы на месте."
        let long = Array(repeating: "слово", count: 30).joined(separator: " ")
        let chunks = SemanticEncoder.chunks(short + " " + long + ".")
        // короткое предложение отдельно, длинное — два словных чанка
        #expect(chunks.count == 3, "\(chunks)")
        #expect(chunks[0] == short)
        let n1 = SemanticEncoder.wordCount(chunks[1])
        let n2 = SemanticEncoder.wordCount(chunks[2])
        #expect(n1 == 15)
        #expect(n2 == 15)
    }

    /// Регресс: обычный текст с предложениями ≤25 слов группируется
    /// в чанки по 1–3 предложения (~250 симв.) — как раньше.
    @Test func punctuatedGroupingUnchanged() {
        let text = "Первое предложение о делах. Второе предложение о планах. "
                 + "Третье предложение о погоде. Четвёртое предложение о еде."
        let chunks = SemanticEncoder.chunks(text)
        #expect(chunks.count == 2, "3+1 предложения: \(chunks)")
    }
}
