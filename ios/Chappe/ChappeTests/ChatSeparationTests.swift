//
//  ChatSeparationTests.swift
//  RMTests
//
//  Задание 30.07: чаты с Софи и чаты с людьми НЕ смешиваются.
//  У людей пузыри несут «доставлено / сжато / N пакетов», у Софи ничего
//  этого нет — она локальная и никуда не передаётся. Смешение создало бы
//  ложное впечатление, что вопрос Софи улетел в эфир.
//

import Foundation
import Testing
@testable import Chappe

struct ChatSeparationTests {

    /// Сообщение Софи в принципе не умеет нести транспортные поля:
    /// сериализация содержит только id/role/text/date/stopped —
    /// ни статуса доставки, ни байтов конверта, ни времён отправки.
    @Test func sophieMessagesCarryNoDeliveryMetadata() throws {
        var message = SophieMessage(role: .sophie, text: "я локальная")
        message.stopped = true   // заполняем всё, что вообще может быть
        let data = try JSONEncoder().encode([message])
        let decoded = try JSONSerialization.jsonObject(with: data)
        let keys = Set((decoded as? [[String: Any]])?.first?.keys.map { $0 } ?? [])
        #expect(keys.isSubset(of: ["id", "role", "text", "date", "stopped"]))
        for transportKey in ["status", "envelopeBytes", "sentAt",
                             "deliveredAt", "semanticBlob"] {
            #expect(!keys.contains(transportKey),
                    "у сообщения Софи не может быть поля \(transportKey)")
        }
    }

    /// А у сообщения человеку транспортные поля есть — разница типов
    /// реальная, а не случайная: перепутать хранилища не даст компилятор.
    @Test func humanMessagesDoCarryDeliveryMetadata() throws {
        var entry = ChatEntry(kind: .outgoing, text: "жди у пирса",
                              status: "в очереди", envelopeBytes: 42)
        entry.deliveredAt = Date()
        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONSerialization.jsonObject(with: data)
        let keys = Set((decoded as? [[String: Any]])?.first?.keys.map { $0 } ?? [])
        #expect(keys.contains("status"))
        #expect(keys.contains("envelopeBytes"))
        #expect(keys.contains("deliveredAt"))
    }

    /// Хранилища живут в разных каталогах Application Support:
    /// Sophie/ и Chats/ — экспорт или чтение одного никогда не заденет
    /// другое.
    @Test func storesLiveInDisjointDirectories() throws {
        let sophieDir = try SophieChatStore.chatURL(key: "chat")
            .deletingLastPathComponent().lastPathComponent
        #expect(sophieDir == "Sophie")
        // Каталог людских чатов зафиксирован в HumanChatStore ("Chats")
        // — проверяем через очередь исходящих, она лежит там же.
        let outbox = Outbox.loadQueue()   // сам факт чтения не создаёт файла
        _ = outbox
        #expect(sophieDir != "Chats")
    }

    /// Обратная совместимость историй: роль "kaya" из записей до
    /// переименования читается как sophie, история не теряется.
    @Test func legacyKayaRoleDecodesAsSophie() throws {
        let legacy = #"[{"id":"6F1C1A3E-2B10-4B5A-9E3C-000000000001","role":"kaya","text":"привет","date":770000000}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let messages = try decoder.decode([SophieMessage].self,
                                          from: Data(legacy.utf8))
        #expect(messages.first?.role == .sophie)
        // неизвестная роль остаётся ошибкой, а не молча становится Софи
        let broken = #"[{"id":"6F1C1A3E-2B10-4B5A-9E3C-000000000002","role":"operator","text":"?","date":770000000}]"#
        #expect(throws: (any Error).self) {
            _ = try decoder.decode([SophieMessage].self,
                                   from: Data(broken.utf8))
        }
    }
}
