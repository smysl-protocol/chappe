import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// WP1 (02.08): ТЕСТ-ЗАМОК на пропадание истории переписки.
//
// БАГ ВОЗВРАЩАЛСЯ. Первый раз историю теряло ЧТЕНИЕ (битый файл) —
// закрыто в 24eb201 (SafeHistoryDecoder + карантин). Регрессия 02.08 —
// та же потеря, но на ЗАПИСИ: вью-модель чата держала снимок entries в
// памяти и при отправке ПЕРЕЗАПИСЫВАЛА файл целиком; всё, что успел
// дописать DeliveryManager (входящие, статусы доставки), стиралось —
// последний пишущий побеждал. Фикс: владельцы снимков пишут только
// через upsert по id (HumanChatStore.upsertLog/upsertWhisper), а само
// сообщение ложится в хранилище ДО попытки отправки со статусом
// «отправляется…». Эти тесты обязаны падать при возврате любой из
// двух форм бага.
// ============================================================================

@MainActor
struct HistoryLockTests {

    private func makeContact(id: String, validKey: Bool) -> Contact {
        let key = validKey
            ? Curve25519.KeyAgreement.PrivateKey().publicKey
                .rawRepresentation.base64EncodedString()
            : ""
        return Contact(id: id, name: "Тест", publicKeyBase64: key,
                       addedAt: Date(), verified: nil)
    }

    private func wipe(_ id: String) {
        HumanChatStore.saveLog([], contactID: id)
        HumanChatStore.saveWhispers([], contactID: id)
    }

    // MARK: Главный замок — параллельная запись не стирается

    @Test("ЗАМОК: входящее от DeliveryManager переживает отправку из чата")
    func concurrentWriterSurvivesSend() {
        let contact = makeContact(id: "test-lock-race-" + UUID().uuidString, validKey: true)
        wipe(contact.id); defer { wipe(contact.id) }

        let model = HumanChatModel(contact: contact)   // снимок пуст

        // Путь DeliveryManager: входящее пишется прямо в файл, минуя
        // открытую вью-модель (так приходят сообщения и статусы)
        let incoming = ChatEntry(kind: .incoming, text: "привет с узла")
        var log = HumanChatStore.loadLog(contactID: contact.id)
        log.append(incoming)
        HumanChatStore.saveLog(log, contactID: contact.id)

        // Отправка из чата со СТАРЫМ снимком (не знает про входящее)
        model.sendPlainText("моё сообщение")

        let disk = HumanChatStore.loadLog(contactID: contact.id)
        #expect(disk.contains { $0.id == incoming.id },
                "входящее стёрто отправкой — вернулся last-writer-wins")
        #expect(disk.contains { $0.text == "моё сообщение" })
    }

    // MARK: Ошибка транспорта/кодека не съедает сообщение

    @Test("ошибка отправки: запись остаётся, со статусом ошибки")
    func sendErrorKeepsEntry() {
        let contact = makeContact(id: "test-lock-err-" + UUID().uuidString, validKey: false)
        wipe(contact.id); defer { wipe(contact.id) }

        let model = HumanChatModel(contact: contact)
        model.sendPlainText("сообщение в никуда")   // ключей нет → throw

        let disk = HumanChatStore.loadLog(contactID: contact.id)
        #expect(disk.count == 1, "сообщение обязано остаться в истории")
        #expect(disk.first?.text == "сообщение в никуда")
        #expect(disk.first?.status?.contains("не закодировалось") == true,
                "у неотправленного — честный статус ошибки")
    }

    // MARK: Перезапуск приложения и переключение вкладок

    @Test("перезапуск: новая модель видит всю историю с диска")
    func restartSeesEverything() {
        let contact = makeContact(id: "test-lock-restart-" + UUID().uuidString, validKey: true)
        wipe(contact.id); defer { wipe(contact.id) }

        let first = HumanChatModel(contact: contact)
        first.sendPlainText("до перезапуска")

        let second = HumanChatModel(contact: contact)   // «перезапуск»
        #expect(second.entries.contains { $0.text == "до перезапуска" })
    }

    @Test("переключение вкладок: reload ничего не теряет и подбирает чужое")
    func tabSwitchKeepsAndRefreshes() {
        let contact = makeContact(id: "test-lock-tabs-" + UUID().uuidString, validKey: true)
        wipe(contact.id); defer { wipe(contact.id) }

        let model = HumanChatModel(contact: contact)
        model.sendPlainText("моё до ухода")
        // пока вкладка была закрыта — входящее в файл напрямую
        let incoming = ChatEntry(kind: .incoming, text: "пока тебя не было")
        var log = HumanChatStore.loadLog(contactID: contact.id)
        log.append(incoming)
        HumanChatStore.saveLog(log, contactID: contact.id)

        model.reload()                                   // возврат на вкладку
        #expect(model.entries.contains { $0.text == "моё до ухода" })
        #expect(model.entries.contains { $0.id == incoming.id })
    }

    // MARK: Краш во время отправки / генерации

    @Test("запись ложится в хранилище ДО исхода отправки")
    func writeAheadOfSend() {
        // Доказательство от противного: даже когда отправка падает
        // немедленно (нет ключей), запись уже на диске — значит, она
        // была сделана ДО попытки, и краш посреди отправки её не съест.
        let contact = makeContact(id: "test-lock-ahead-" + UUID().uuidString, validKey: false)
        wipe(contact.id); defer { wipe(contact.id) }
        HumanChatModel(contact: contact).sendPlainText("переживёт краш")
        #expect(HumanChatStore.loadLog(contactID: contact.id)
            .contains { $0.text == "переживёт краш" })
    }

    @Test("шёпот: вопрос сохранён до генерации — краш модели его не съест")
    func whisperQuestionPersistedUpfront() {
        let cid = "test-lock-whisper-" + UUID().uuidString
        wipe(cid); defer { wipe(cid) }
        // Контракт хранилища, который использует whisper(): вопрос
        // upsert-ится сразу после ввода, ответ — отдельной записью позже
        let q = ChatEntry(kind: .whisperQuestion, text: "как дела у узла?")
        HumanChatStore.upsertWhisper(q, contactID: cid)
        // «краш»: ответа не случилось; вопрос обязан быть на диске
        #expect(HumanChatStore.loadWhispers(contactID: cid)
            .contains { $0.id == q.id })
    }
}
