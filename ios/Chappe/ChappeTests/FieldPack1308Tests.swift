import Foundation
import Testing
import UIKit
import UserNotifications
@testable import Chappe

// ============================================================================
// Замки полевого пакета 13.08 (вторая волна).
//
// 1. «Только Wi-Fi» — владелец снял ВСЕ галочки ручного режима, ожидая
//    прямой Wi-Fi; статус пузыря обещал «доставлю, когда окажетесь
//    рядом», хотя путей не было вовсе. Пустая маска обязана давать
//    честное «пути отключены в настройках».
//    Слом: убрать ветку пустой маски из pathSummary — тест краснеет.
// 2. Share приглашения: SwiftUI Image как Transferable в Telegram не
//    материализуется (Send молча ничего не слал). Шарится ФАЙЛ;
//    ожидание внешнее — сигнатура PNG (байты 89 50 4E 47 из спеки).
//    Слом: вернуть шаринг Image / сломать запись файла — краснеет.
// 3. Демо-чат убран из живого UI: дверь только launch-аргументом
//    --demo-chat (UI-тест клавиатуры). Обычный запуск — двери нет.
// ============================================================================

nonisolated struct FieldPack1308Tests {

    // MARK: 1 — пустая маска транспортов

    @MainActor
    @Test("пустая ручная маска: статус — «пути отключены», не обещание")
    func emptyManualMaskGivesHonestStatus() {
        let ud = UserDefaults.standard
        let savedMode = ud.string(forKey: TransportMode.modeKey)
        let savedMask = ud.stringArray(forKey: TransportMode.maskKey)
        defer {
            ud.set(savedMode, forKey: TransportMode.modeKey)
            ud.set(savedMask, forKey: TransportMode.maskKey)
        }

        TransportMode.isManual = true
        TransportMode.manualMask = []
        #expect(DeliveryManager.shared.pathSummary
                == "пути отключены в настройках", Comment(rawValue:
                "сняты все галочки — статус обязан сказать об этом, а не "
                + "обещать «доставлю, когда окажетесь рядом» (поле 13.08)"))

        // авто-режим пустой маской не отравляется
        TransportMode.isManual = false
        #expect(DeliveryManager.shared.pathSummary
                != "пути отключены в настройках",
                "в авто-режиме маска не действует")
    }

    // MARK: 2 — файл приглашения для share-листа

    @Test("приглашение шарится PNG-файлом с валидной сигнатурой")
    func inviteFileIsRealPNG() throws {
        let url = try #require(MyQRView.inviteFileURL("rm://contact/test"),
                               "файл приглашения обязан создаваться")
        let data = try Data(contentsOf: url)
        // сигнатура PNG из спецификации (не из проверяемого кода)
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47],
                Comment(rawValue: "шарится обязан НАСТОЯЩИЙ PNG-файл — "
                + "Image-Transferable в Telegram давал пустой «Send»"))
        #expect(data.count > 500, "PNG с QR не может быть крошечным")

        // повторный вызов перезаписывает (payload меняется после сброса)
        let url2 = try #require(MyQRView.inviteFileURL("rm://contact/other"))
        #expect(url2 == url, "файл один, содержимое перезаписывается")
        let data2 = try Data(contentsOf: url2)
        #expect(data2 != data, "новый payload — новое содержимое файла")
    }

    // MARK: 2б — «получено HH:MM» на запоздавших входящих

    // Просьба владельца 13.08: пузырь показывает время ОТПРАВКИ, и у
    // запоздавшего сообщения (BLE-пачки, релей) непонятно, когда оно
    // реально пришло. Запоздал больше минуты — рядом честное
    // «получено HH:MM»; свежий — только время отправки, без шума.
    // Ожидания внешние: литералы строк посчитаны руками.
    @Test("запоздавший входящий несёт «получено HH:MM», свежий — нет")
    func lateIncomingShowsReceivedStamp() {
        let sent = Date(timeIntervalSince1970: 1_760_000_000)   // 09:33 UTC
        var late = ChatEntry(kind: .incoming, text: "запоздалое",
                             date: sent)
        late.receivedAt = sent.addingTimeInterval(190)
        let sentHHMM = ChatEntry.hhmm(sent)
        let recvHHMM = ChatEntry.hhmm(sent.addingTimeInterval(190))
        #expect(late.timeLine == "\(sentHHMM) · получено \(recvHHMM)",
                Comment(rawValue: "задержка >1 мин обязана быть видна: "
                + "время отправки · получено HH:MM"))

        var fresh = ChatEntry(kind: .incoming, text: "свежее", date: sent)
        fresh.receivedAt = sent.addingTimeInterval(20)
        #expect(fresh.timeLine == sentHHMM,
                "свежее (в пределах минуты) — без «получено», не шумим")

        var outgoing = ChatEntry(kind: .outgoing, text: "моё", date: sent)
        outgoing.receivedAt = sent.addingTimeInterval(190)
        #expect(!outgoing.timeLine.contains("получено"),
                "«получено» — только про входящие")
    }

    // MARK: 2в — контент уведомления: группировка по собеседнику

    // Б1 (13.08, исход «показано, но не увидел»): без threadIdentifier
    // залп баннеров из одного чата хоронил себя в шторке. Контент —
    // чистая сборка, ожидания — литералы. Слом: убрать threadIdentifier
    // из makeContent — тест краснеет.
    @Test("баннеры группируются по собеседнику (threadIdentifier)")
    func notificationGroupsBySender() {
        let named = IncomingNotifier.makeContent(senderName: "Али",
                                                 text: "привет")
        #expect(named.threadIdentifier == "Али", Comment(rawValue:
                "баннеры одного собеседника обязаны складываться стопкой "
                + "— иначе залп хоронит сам себя в шторке"))
        #expect(named.title == "Али")
        #expect(named.body == "привет")

        let anon = IncomingNotifier.makeContent(senderName: nil,
                                                text: "текст")
        #expect(anon.threadIdentifier == "chappe.incoming",
                "без имени — общая стопка, не пустой идентификатор")
        #expect(anon.title == "Новое сообщение")
    }

    // MARK: 3 — демо-чат только за launch-аргументом

    @MainActor
    @Test("демо-чат в живом UI выключен: без --demo-chat двери нет")
    func demoChatHiddenByDefault() {
        // тест-раннер не передаёт --demo-chat — дверь обязана быть закрыта
        #expect(!ProcessInfo.processInfo.arguments.contains("--demo-chat"),
                "предусловие: раннер без launch-аргумента")
        #expect(ChatListView.demoChatEnabled == false, Comment(rawValue:
                "демо-чат «Как это выглядит» убран из живого списка "
                + "(полевой пакет 13.08); вход остался только UI-тестам"))
    }
}

// МЕГА-10 (14.08): в авто галки не действуют — подпись говорит это
// словами. Слом: убрать «Галочки действуют только…» из footerText.
extension FieldPack1308Tests {
    @Test("подпись транспорта: авто говорит про все пути и галки")
    func autoFooterExplainsItself() {
        let auto = TransportMode.footerText(manual: false)
        #expect(auto.contains("ВСЕ пути"), Comment(rawValue:
                "человек, переключившись в авто, обязан прочитать, что "
                + "разрешено всё (вечер 13.08: «снял галочки» в авто)"))
        #expect(auto.contains("Ручном выборе"),
                "подпись ведёт к месту, где галки действуют")
        #expect(TransportMode.footerText(manual: true)
                .contains("отмеченными путями"))
    }
}
