import Testing
import Foundation
@testable import Chappe

// ============================================================================
// Живой второй конец «рядом» на Маке (фаза 1, проверка 07.08).
//
// Mac не запускает iOS-приложение обычным двойным щелчком, но ХОСТ ТЕСТОВ
// в назначении «My Mac (Designed for iPad)» — это то же приложение с
// настоящим CoreBluetooth. Этот файл поднимает продуктовый транспорт
// (NearbyTransport + DeliveryManager, без подмен) и работает вторым
// телефоном: слушает и отправляет.
//
// Не часть обычной сюиты: без переменной окружения RM_LIVE_NEARBY тесты
// не делают ничего (иначе каждая сборка вставала бы на минуту).
//   RM_LIVE_NEARBY=listen  — слушать N секунд, печатать принятое;
//   RM_LIVE_NEARBY=send    — добавить контакт из RM_PEER_CARD и слать
//                            текст RM_TEXT, ждать подтверждения.
// ============================================================================

struct LiveNearbyEndpointTests {

    private static var mode: String? {
        ProcessInfo.processInfo.environment["RM_LIVE_NEARBY"]
    }
    private static var seconds: Double {
        Double(ProcessInfo.processInfo.environment["RM_LIVE_SECONDS"] ?? "90")
            ?? 90
    }

    @Test @MainActor func liveEndpoint() async throws {
        guard let mode = Self.mode else { return }   // обычная сборка: пропуск
        let env = ProcessInfo.processInfo.environment

        if let name = env["RM_NAME"] { Identity.displayName = name }
        print("[live] моя карточка: \(ContactStore.myPayloadBase64() ?? "нет")")
        print("[live] мой отпечаток: \(Identity.myFingerprint() ?? "нет")")

        // продуктовый путь: тот же координатор, что включает ChappeApp
        _ = DeliveryManager.shared
        NearbyTransport.shared.setActive(true)

        if mode == "send" {
            guard let card = env["RM_PEER_CARD"],
                  let contact = ContactStore.parse(card) else {
                Issue.record("RM_PEER_CARD не разобрана")
                return
            }
            _ = ContactStore.upsert(contact)
            let text = env["RM_TEXT"] ?? "проба связи рядом"
            let entry = ChatEntry(kind: .outgoing, text: text)
            let (codec, data) = TextCodec.best(text)
            let queued = try Outbox.enqueueSealed(
                innerCodec: codec, data: data, to: contact, entryID: entry.id)
            var log = HumanChatStore.loadLog(contactID: contact.id)
            var stamped = entry
            stamped.envelopeBytes = queued.totalBytes
            stamped.wireMsgID = Int(queued.msgID)
            log.append(stamped)
            HumanChatStore.saveLog(log, contactID: contact.id)
            print("[live] в очереди msgID=\(queued.msgID), "
                + "\(queued.totalBytes) Б контакту \(contact.id)")
        }

        // ждём: соседи появляются не мгновенно, насос тикает каждые 2 с
        let deadline = Date().addingTimeInterval(Self.seconds)
        var lastPeers = -1
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(3))
            let peers = NearbyTransport.shared.peerCount
            if peers != lastPeers {
                print("[live] соседей: \(peers) · \(NearbyTransport.shared.statusLine)")
                lastPeers = peers
            }
            DeliveryManager.shared.pushQueue()
            for contact in ContactStore.load() {
                for e in HumanChatStore.loadLog(contactID: contact.id).suffix(4) {
                    let via = ChatEntry.pathWord(e.sentVia) ?? "—"
                    print("[live] \(e.kind) «\(e.text.prefix(40))» путь=\(via) "
                        + "отпр=\(e.sentAt != nil) дост=\(e.deliveredAt != nil) "
                        + "прочт=\(e.readAt != nil) статус=\(e.status ?? "-")")
                }
            }
        }
        NearbyTransport.shared.setActive(false)
    }
}
