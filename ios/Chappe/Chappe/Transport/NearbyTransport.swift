import Foundation
import Combine

// ============================================================================
// Транспорт «рядом» (фаза 1, бриф 07.08): телефоны с открытым приложением
// переписываются напрямую, без интернета и радиоустройства.
//
// Для пользователя это ОДИН транспорт без настройки. Внутри — каналы:
//  - BLE (BleLink) — работает сейчас: обнаружение и передача конвертов;
//  - Wi-Fi Aware (iOS 26, iPhone 12+) — слот под объёмное плечо; ждёт
//    entitlement Apple. Когда появится: канал добавляется сюда, выбор в
//    send() — по размеру пакета (объёмное → Wi-Fi, короткое → BLE), при
//    недоступности МОЛЧА деградируем до BLE. Слов «Wi-Fi Aware недоступен»
//    в интерфейсе не существует.
//
// Приватность (дизайн ДО реализации, бриф п. «условие»):
//  - в рекламе только service UUID, общий для всех установок Chappe;
//    имени устройства/человека в эфире нет (LocalName не ставится);
//  - MAC ротирует сама iOS (~15 мин; подтверждено замером 06.08);
//  - личность — только внутри шифрованного конверта: пакет уходит веером
//    всем соседям, получатель узнаёт своё по ротируемому dst (эпохи
//    конверта v2, dstIsForMe), рукопожатий с идентификаторами нет;
//  - эфир живёт только при активном приложении (setActive из scenePhase) —
//    присутствие не транслируется круглосуточно.
// Постороннему видно «рядом кто-то с Chappe, пока приложение открыто»,
// но не КТО и не тот же ли это человек, что вчера.
//
// Политика активности: повод — открытое приложение (фаза 1; фоновое —
// фаза 2). Нет повода — каналы остановлены и эфир молчит.
// ============================================================================

@MainActor
final class NearbyTransport: ObservableObject {

    static let shared = NearbyTransport()

    /// Живые соседи (для диагностики и решения «есть ли путь»).
    @Published private(set) var peerCount = 0
    private(set) var active = false

    /// Входящие конверт-блобы (DeliveryManager.handle).
    var onReceive: (@Sendable ([UInt8]) -> Void)?

    private var ble: BleLink?
    /// Второй канал: Wi-Fi Aware (iOS 26+, только между знакомыми
    /// телефонами). Нет — молча остаётся BLE.
    private var wifi: AnyObject?
    @Published private(set) var wifiPeerCount = 0

    private init() {}

    /// Политика активности: включает/останавливает все каналы.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            let link = BleLink()
            link.onReceive = { [weak self] packet in
                Task { @MainActor in self?.route(packet) }
            }
            link.onPeersChanged = { [weak self] count in
                Task { @MainActor in
                    // пульс соседей (правило 3, полевой прогон 08.08:
                    // «через интернет» при телефонах рядом — а дневник
                    // не умел сказать, видели ли мы соседа вообще)
                    let before = self?.peerCount ?? 0
                    if count != before {
                        TransportDiary.note("[рядом] соседей: \(count)")
                    }
                    self?.peerCount = count
                    // окно открылось: доставка не ждёт хвост бэкоффа
                    // (корень квантования 60–67 с, 14.08)
                    if count > 0, before == 0 {
                        DeliveryManager.shared.nearbyWindowOpened()
                    }
                }
            }
            link.start()
            ble = link
            startWiFiIfPossible()
            TransportDiary.note("[рядом] эфир включён (приложение активно)")
        } else {
            ble?.stop()
            ble = nil
            if #available(iOS 26.0, *), let channel = wifi as? NearbyWiFiChannel {
                channel.stop()
            }
            wifi = nil
            wifiPeerCount = 0
            peerCount = 0
            TransportDiary.note("[рядом] эфир остановлен (нет повода)")
        }
    }

    /// Wi-Fi-плечо поднимается, только если есть знакомые телефоны;
    /// иначе тишина — человеку об этом не сообщается.
    private func startWiFiIfPossible() {
        guard #available(iOS 26.0, *) else { return }
        Task { @MainActor in
            guard await NearbyWiFiChannel.hasPairedDevices() else { return }
            let channel = NearbyWiFiChannel()
            channel.onReceive = { [weak self] packet in
                Task { @MainActor in self?.route(packet) }
            }
            channel.onPeersChanged = { [weak self] count in
                Task { @MainActor in self?.wifiPeerCount = count }
            }
            channel.start()
            wifi = channel
        }
    }

    /// Веер всем соседям; успех = принял хоть один живой сосед.
    ///
    /// Выбор канала (человек о нём не знает и не участвует): есть живое
    /// Wi-Fi-плечо — берём его, оно быстрее и не имеет узкого горла;
    /// нет — BLE. Провал Wi-Fi мгновенно откатывается на BLE в том же
    /// вызове: молчание одного канала не должно стоить сообщения.
    func send(_ packet: [UInt8],
              completion: @escaping @Sendable (Bool) -> Void) {
        if #available(iOS 26.0, *), wifiPeerCount > 0,
           let channel = wifi as? NearbyWiFiChannel, channel.send(packet) {
            completion(true)
            return
        }
        guard let ble, peerCount > 0 else {
            completion(false)
            return
        }
        ble.send(packet, toHost: "", completion: completion)
    }

    /// Развилка входящих: объявления знакомства (баннер, 08.08)
    /// перехватываются ДО пути конверта — это не envelope-пакет.
    private func route(_ packet: [UInt8]) {
        // паддинг быстрых каналов (№7) снимается до развилки: под
        // обёрткой может лежать и объявление знакомства, и конверт
        var packet = packet
        if packet.first == WirePadding.marker {
            guard let inner = WirePadding.unwrap(packet) else { return }
            packet = inner
        }
        switch Self.routeVerdict(packet) {
        case .droppedIntro:
            // Знакомство «одним баннером» УБРАНО (вердикт владельца
            // 14.08: полевые прогоны нестабильны — чат создавался на
            // одном из двух телефонов, задержки до минут; знакомство —
            // только QR). Кадры старых сборок отбрасываются молча.
            TransportDiary.note("[знакомство] кадр отброшен — фича убрана")
        case .deliver:
            onReceive?(packet)
        }
    }

    /// Развилка приёма — чистая (под замком): интро-кадры старых
    /// сборок узнаются по магии и НЕ доставляются никуда.
    enum RouteVerdict: Equatable { case droppedIntro, deliver }
    nonisolated static func routeVerdict(_ packet: [UInt8]) -> RouteVerdict {
        packet.starts(with: IntroduceWire.magic) ? .droppedIntro : .deliver
    }

    /// Строка для Dev-диагностики (пользовательский UI её не показывает).
    var statusLine: String {
        guard active else { return "эфир выключен" }
        let base = ble?.stateLine ?? "включается…"
        return wifiPeerCount > 0 ? base + " · быстрый канал: \(wifiPeerCount)"
                                 : base
    }
}
