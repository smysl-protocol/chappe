import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Ночной радиопрогон 02.08: статусы доставки и прочтения.
//
// Замки на то, что чинилось живым эфиром:
//  - две отметки времени и их состояния (просьба владельца);
//  - отметка прочтения как класс конверта READ (0x6) — её в протоколе
//    не было вовсе, второе время не могло позеленеть;
//  - wireMsgID: без него ACK и отметку прочтения не с чем сопоставить
//    (ночью это и был корень «зелёного нет»);
//  - «узлов нет» было ЗАШИТО в статус текстового сообщения и врало.
// ============================================================================

nonisolated struct DeliveryStatusTests {

    // Замок А3 (полевой прогон 09.08): после длинного сообщения мелкие
    // переставали помечаться прочитанными. Корень — at-most-once:
    // readAt штамповался ДО отправки квитанции; залп после длинного
    // конкурировал с ним за канал, потерянная квитанция терялась
    // навсегда (фильтр readAt == nil её больше не выбирал). Теперь
    // штамп — только по подтверждению канала; неудача = повтор при
    // следующем открытии чата.
    @Test("квитанция прочтения штампуется только по подтверждению канала")
    @MainActor
    func receiptStampedOnlyOnConfirmedSend() async throws {
        let cid = "тест-квитанции-0908"
        var entry = ChatEntry(kind: .incoming,
                              text: "мелкое после длинного 09.08")
        entry.wireMsgID = 41414
        HumanChatStore.saveLog([entry], contactID: cid)
        defer { HumanChatStore.saveLog([], contactID: cid) }
        let dm = DeliveryManager.shared

        // канал провалил отправку — штампа нет, повтор остаётся возможным
        dm.sendReadReceipts(contactID: cid) { _, done in done(false) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(HumanChatStore.loadLog(contactID: cid).first?.readAt == nil,
                Comment(rawValue:
                "неотправленная квитанция помечена отосланной — при "
                + "потере канала она пропадёт навсегда (стопор 09.08)"))

        // канал подтвердил — штамп встаёт
        dm.sendReadReceipts(contactID: cid) { _, done in done(true) }
        try await until("readAt проставлен") {
            HumanChatStore.loadLog(contactID: cid).first?.readAt != nil
        }
        // повторное открытие чата не шлёт дубликаты уже отмеченного
        var sent = 0
        dm.sendReadReceipts(contactID: cid) { _, done in sent += 1; done(true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(sent == 0, "отмеченное второй раз не квитируется")
    }

    private func entry(sent: Bool = false, delivered: Bool = false,
                       read: Bool = false) -> ChatEntry {
        var e = ChatEntry(kind: .outgoing, text: "тест")
        if sent { e.sentAt = Date() }
        if delivered { e.deliveredAt = Date() }
        if read { e.readAt = Date() }
        return e
    }

    @Test("состояния двух отметок: очередь → отправлено → доставлено → прочитано")
    func stampStates() {
        #expect(entry().stampState == .queued)
        #expect(entry(sent: true).stampState == .sent)
        #expect(entry(sent: true, delivered: true).stampState == .delivered)
        #expect(entry(sent: true, delivered: true, read: true).stampState
                == .read)
    }

    @Test("второе время появляется только после доставки")
    func secondStampAppearsWithDelivery() {
        #expect(entry(sent: true).stampDelivered == nil,
                "доставки не было — второго времени быть не должно")
        let delivered = entry(sent: true, delivered: true)
        #expect(delivered.stampDelivered != nil)
        #expect(delivered.stampSent.count == 5, "HH:MM")
    }

    @Test("класс READ отделён от ACK и от TEXT")
    func readClassIsDistinct() {
        #expect(Envelope.classRead == 0x6)
        #expect(Envelope.classRead != Envelope.classAck)
        #expect(Envelope.classRead != Envelope.classText)
    }

    @Test("конверт READ разбирается заголовком и не путается с ACK")
    func readEnvelopeParses() throws {
        // [версия|класс][флаги][msgID LE][прочитанный msgID LE]
        let packet: [UInt8] = [(1 << 4) | Envelope.classRead, 0,
                               0x34, 0x12, 0xCD, 0xAB]
        let header = try Envelope.decodeHeader(packet)
        #expect(header.msgClass == Envelope.classRead)
        #expect(header.msgID == 0x1234)
        let readID = UInt16(packet[4]) | UInt16(packet[5]) << 8
        #expect(readID == 0xABCD)
    }

    @Test("старый приёмник отвергает READ честно, не падая")
    func oldReceiverRejectsReadGracefully() {
        let packet: [UInt8] = [(1 << 4) | Envelope.classRead, 0, 1, 0, 2, 0]
        // заголовок разбирается (версия знакомая), а полный разбор
        // отдаёт ошибку «неизвестный класс» — не мусор и не падение
        #expect(throws: (any Error).self) {
            _ = try EnvelopeDecoder.decode(packet)
        }
    }

    @Test("ЗАМОК: wireMsgID переживает сохранение истории")
    func wireMsgIDSurvivesStorage() throws {
        var e = ChatEntry(kind: .outgoing, text: "с идентификатором")
        e.wireMsgID = 4242
        let data = try JSONEncoder().encode([e])
        let back = try JSONDecoder().decode([ChatEntry].self, from: data)
        #expect(back.first?.wireMsgID == 4242,
                "без wireMsgID нечего сопоставлять с ACK и прочтением")
    }

    @Test("старые записи без новых полей читаются (аддитивность)")
    func oldEntriesStillDecode() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","kind":"outgoing","text":"старая",
          "date":770000000}]
        """
        let back = try JSONDecoder().decode(
            [ChatEntry].self, from: Data(legacy.utf8))
        #expect(back.first?.wireMsgID == nil)
        #expect(back.first?.readAt == nil)
        #expect(back.first?.stampState == .queued)
    }
}
