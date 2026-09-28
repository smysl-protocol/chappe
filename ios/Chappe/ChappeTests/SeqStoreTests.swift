import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Замки seq-стора (шов рев B, транспортная половина, 14.08).
// Слом: перевести next() на память-без-записи или UserDefaults —
// монотонность через перечтение Keychain краснеет; ослабить правило
// позиций (принимать любой seq) — краснеет реплей-замок.
// ============================================================================

nonisolated struct SeqStoreTests {

    private func freshID() -> String { "SEQ-TEST-\(UUID().uuidString.prefix(8))" }

    @Test("seq монотонен и переживает перечтение стора")
    func seqMonotonicAndPersistent() {
        let id = freshID()
        defer { SeqStore.purge(contactID: id) }
        #expect(SeqStore.lastIssued(contactID: id) == 0, "чистый старт")
        let first = SeqStore.next(contactID: id)
        let second = SeqStore.next(contactID: id)
        let third = SeqStore.next(contactID: id)
        #expect(first == 1 && second == 2 && third == 3, Comment(rawValue:
                "seq обязан быть монотонным без дыр — на нём порядок ленты"))
        // перечтение из Keychain (не память): lastIssued видит запись
        #expect(SeqStore.lastIssued(contactID: id) == 3, Comment(rawValue:
                "счётчик обязан ЖИТЬ в защищённом сторе, не в памяти — "
                + "иначе перезапуск раздаёт повторные seq (подпись п.2)"))
        SeqStore.purge(contactID: id)
        #expect(SeqStore.lastIssued(contactID: id) == 0,
                "удаление контакта чистит счётчик")
    }

    @Test("приёмник: рост — ordered, запоздание — stale, провал — сброс")
    func incomingVerdicts() {
        let id = freshID()
        defer { SeqStore.purge(contactID: id) }
        #expect(SeqStore.noteIncoming(contactID: id, seq: 5) == .ordered)
        #expect(SeqStore.noteIncoming(contactID: id, seq: 7) == .ordered)
        #expect(SeqStore.noteIncoming(contactID: id, seq: 6) == .stale,
                "запоздавший кадр в пределах окна — не сброс")
        #expect(SeqStore.noteIncoming(contactID: id, seq: 7000) == .ordered)
        #expect(SeqStore.noteIncoming(contactID: id, seq: 3) ==
                .resetDetected, Comment(rawValue:
                "резкий провал seq = переустановка отправителя — лента "
                + "обязана честно откатиться к порядку прихода (шов №4)"))
        // после сброса отсчёт начинается заново
        #expect(SeqStore.noteIncoming(contactID: id, seq: 4) == .ordered)
    }

    @Test("позиция со старым seq отбрасывается — релей не переигрывает")
    func stalePositionRejected() {
        let id = freshID()
        defer { SeqStore.purge(contactID: id) }
        #expect(SeqStore.acceptPosition(contactID: id, seq: 10))
        #expect(!SeqStore.acceptPosition(contactID: id, seq: 9), Comment(
                rawValue: "устаревшая точка не смеет переиграть свежую "
                + "(шов №4: реплей позиций)"))
        #expect(!SeqStore.acceptPosition(contactID: id, seq: 10),
                "повтор того же seq — тоже реплей")
        #expect(SeqStore.acceptPosition(contactID: id, seq: 11))
    }

    @Test("способности пира: 5/6 дают revB, session2 — только кадр 6")
    func peerCapsProgression() {
        let id = freshID()
        defer { PeerCaps.purge(contactID: id) }
        #expect(PeerCaps.load(contactID: id) == PeerCaps.Caps())
        PeerCaps.markRevB(contactID: id)
        #expect(PeerCaps.load(contactID: id).revB)
        #expect(!PeerCaps.load(contactID: id).session2, Comment(rawValue:
                "кадр 5 доказывает рев B, но НЕ эпоху — session2 только "
                + "по session2-кадру (подпись п.5)"))
        PeerCaps.markSession2(contactID: id)
        #expect(PeerCaps.load(contactID: id).session2)
        PeerCaps.purge(contactID: id)
        #expect(PeerCaps.load(contactID: id) == PeerCaps.Caps())
    }
}
