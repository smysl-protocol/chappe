import Foundation
import UIKit
import UserNotifications

// ============================================================================
// Локальное уведомление о входящем (фон — ядро, поручение владельца
// 10.08): полевой прогон показал — свёрнутый приёмник разгружает
// копилку молча, человек не знает о сообщениях, пока не откроет
// приложение сам. Уведомление закрывает половину боли фона ещё до
// полного фонового приёма от узла.
//
// Приватность: в уведомлении имя контакта и текст — норма мессенджера;
// система сама прячет содержимое на заблокированном экране по
// настройкам телефона. Активное приложение уведомление не постит —
// человек и так в ленте.
// ============================================================================

@MainActor
enum IncomingNotifier {

    private static var authorizationAsked = false

    /// Разрешение спрашивается один раз за запуск — при первом
    /// обращении (старт приложения). Отказ уважается молча.
    static func requestAuthorizationOnce() {
        guard !authorizationAsked else { return }
        // тест-хост: системный диалог разрешения висел над раннером —
        // «The test runner hung before establishing connection»
        // (пойман гейтом числа тестов, 10.08)
        guard NSClassFromString("XCTestCase") == nil else { return }
        authorizationAsked = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]) { granted, _ in
            TransportDiary.note("[уведомления] разрешение: "
                                + (granted ? "да" : "нет"))
        }
    }

    /// Контент баннера — чистая сборка (замок Б1, 13.08):
    /// threadIdentifier группирует баннеры по собеседнику — залп из
    /// одного чата складывается стопкой, а не хоронит себя в шторке
    /// (исход «показано, но не увидел»).
    nonisolated static func makeContent(senderName: String?,
                                        text: String)
    -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = senderName ?? "Новое сообщение"
        content.body = text
        content.sound = .default
        content.threadIdentifier = senderName ?? "chappe.incoming"
        return content
    }

    /// Показать уведомление о входящем, если приложение не на экране.
    /// Пульс в дневник на каждый вызов (правило «тишина не есть
    /// отказ»): в поле «уведомления не приходят» иначе неотличимо от
    /// «сообщения не доходят» — дневник называет исход каждого входящего.
    /// Отказ системы (throttle/лимит) — один повтор через 2 с (Б1-б).
    static func post(senderName: String?, text: String) {
        guard UIApplication.shared.applicationState != .active else {
            TransportDiary.note("[уведомления] входящее при активном "
                                + "приложении — баннер не нужен")
            return
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: makeContent(senderName: senderName, text: text),
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else {
                TransportDiary.note("[уведомления] показано (фон)")
                return
            }
            TransportDiary.note("[уведомления] ОТКАЗ показа: "
                + "\(error.localizedDescription) — повтор через 2 с")
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                UNUserNotificationCenter.current().add(request) { retryError in
                    TransportDiary.note(retryError == nil
                        ? "[уведомления] показано со второй попытки"
                        : "[уведомления] ОКОНЧАТЕЛЬНЫЙ отказ: "
                            + "\(retryError!.localizedDescription)")
                }
            }
        }
    }

    /// Статус разрешения — для строки в Настройках (Б1-б, 13.08):
    /// «уведомления запрещены системой» должно быть видно в приложении,
    /// а не выясняться полевым разбором.
    static func authorizationDenied() async -> Bool {
        let settings = await UNUserNotificationCenter.current()
            .notificationSettings()
        return settings.authorizationStatus == .denied
    }
}
