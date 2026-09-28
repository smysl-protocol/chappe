import Foundation
import Testing
@testable import Chappe

// ============================================================================
// ЗАМОК на ПРИЧИНЫ отката в текст (решение владельца 03.08).
//
// Повод: кодек отказывался кодировать сверхдлинный литерал, а человек
// видел «пивот пустой» — причина врала, потому что все отказы кодека
// сваливались в одну ветку guard. «Диагностика, которая врёт, дороже
// отсутствующей»: тест проверяет не факт отката, а ЧТО ИМЕННО сказано.
//
// Правило, которое здесь закрепляется: каждый вид отказа даёт СВОЮ
// причину, причины не пересекаются и не совпадают дословно.
// ============================================================================

nonisolated struct FallbackReasonTests {

    /// Все причины отката, которые умеет выдавать конвейер.
    /// Список ведётся руками: новый вид отказа обязан появиться здесь,
    /// иначе тест на уникальность его не увидит.
    static let knownReasons = [
        "короткое — текстом дословно",
        "локальная модель недоступна",
        "текст короче семантики",
        "модель не ответила",
        "пивот слишком короткий",
        "пивот пустой",
        "не помещается",              // сверхдлинный литерал (03.08)
    ]

    @Test("причины отката не повторяются дословно")
    func reasonsAreDistinct() {
        let unique = Set(Self.knownReasons)
        #expect(unique.count == Self.knownReasons.count,
                "две ветки отказа с одинаковым текстом неразличимы в логе")
    }

    @Test("короткое сообщение даёт СВОЮ причину, а не общую")
    func shortMessageReason() async {
        let outcome = await SemanticEncoder.prepare(russian: "ок")
        guard case .text(let reason, _) = outcome else {
            Issue.record("короткое обязано уходить текстом")
            return
        }
        #expect(reason.contains("короткое"),
                Comment(rawValue: "причина «\(reason)» не про длину"))
        #expect(!reason.contains("пивот"),
                "причина не должна ссылаться на пивот: его не считали")
    }

    @Test("отказ кодека на длинном литерале объясняется длиной, а не пивотом")
    func literalOverflowReasonIsHonest() throws {
        let codec = try #require(RMCodec.shared)
        do {
            _ = try codec.encode([.lit(String(repeating: "я", count: 300))])
            Issue.record("сверхдлинный литерал обязан быть отвергнут")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(text.contains("не помещается"),
                    Comment(rawValue: "причина «\(text)» не называет длину"))
            #expect(!text.contains("пивот"),
                    "именно эта подмена и была дефектом 03.08")
        }
    }

    @Test("причина отказа читается человеком, а не кодом ошибки")
    func reasonsAreHumanReadable() {
        for reason in Self.knownReasons {
            #expect(reason.count >= 8, Comment(rawValue:
                "причина «\(reason)» слишком коротка, чтобы что-то объяснить"))
            #expect(!reason.contains("Error"), "код ошибки вместо объяснения")
            #expect(!reason.contains("nil"), "внутренности наружу")
            // причина обязана быть по-русски: её читает владелец
            #expect(reason.rangeOfCharacter(from: CharacterSet(
                charactersIn: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя")) != nil,
                Comment(rawValue: "причина «\(reason)» не по-русски"))
        }
    }
}
