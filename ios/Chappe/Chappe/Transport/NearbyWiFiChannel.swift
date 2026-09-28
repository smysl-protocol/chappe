import Foundation
import Network
import WiFiAware

// ============================================================================
// Канал Wi-Fi Aware внутри транспорта «рядом» (фаза 1, 07.08).
//
// Для пользователя этого файла не существует: он не выбирает между BLE и
// Wi-Fi и не знает, что их два. NearbyTransport берёт лучший доступный.
// Нет спаренных устройств, старая iOS, отказ радио — канал молча не
// поднимается, остаётся BLE. Слов «Wi-Fi Aware недоступен» в интерфейсе нет.
//
// Устройство канала (проверено по SDK iOS 26.5):
//  - обе стороны объявляют сервис `_chappe-near._tcp` в Info.plist
//    (ключ WiFiAwareServices) и имеют entitlement com.apple.developer.wifi-aware;
//  - публикующая сторона поднимает NetworkListener поверх
//    WAPublisherListener, подписчик ищет через NetworkBrowser поверх
//    WASubscriberBrowser; и то и другое работает ТОЛЬКО со спаренными
//    устройствами (WAPairedDevice) — отсюда требование спаривания,
//    которое мы прячем в момент QR-знакомства (NearbyPairing);
//  - шифрование канала делает система, поверх всё равно идёт наш конверт:
//    транспорт плейнтекста не видит никогда.
//
// Рамка на проводе — та же, что у LanLink: [длина u32 LE][блоб].
// ============================================================================

// nonisolated + замыкания под замком (А4, 09.08: класс дефекта LanLink —
// var-ссылка без синхронизации при @unchecked Sendable бьёт кучу, а
// изолированный deinit возит деаллокацию джобой на главную очередь).
@available(iOS 26.0, *)
nonisolated final class NearbyWiFiChannel: @unchecked Sendable {

    /// Имя сервиса из Info.plist (менять только вместе с ним).
    static let serviceName = "_chappe-near._tcp"

    /// Оба замыкания — только под lock (см. комментарий класса).
    private var _onReceive: (@Sendable ([UInt8]) -> Void)?
    private var _onPeersChanged: (@Sendable (Int) -> Void)?
    var onReceive: (@Sendable ([UInt8]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onReceive }
        set { lock.lock(); defer { lock.unlock() }; _onReceive = newValue }
    }
    var onPeersChanged: (@Sendable (Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onPeersChanged }
        set { lock.lock(); defer { lock.unlock() }; _onPeersChanged = newValue }
    }
    /// Сколько соседей на связи по этому каналу (под lock).
    private(set) var peerCount = 0

    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private let lock = NSLock()
    private var outbound: [UUID: @Sendable ([UInt8]) -> Void] = [:]

    /// Есть ли вообще с кем говорить: хоть одно спаренное устройство.
    static func hasPairedDevices() async -> Bool {
        guard let devices = try? await WAPairedDevice.allDevices.current()
        else { return false }
        return !devices.isEmpty
    }

    func start() {
        stop()
        // публикуем свой сервис для спаренных устройств
        listenerTask = Task { [weak self] in
            guard let service = WAPublishableService.allServices[Self.serviceName]
            else { return }   // сервис не объявлен — молчим, остаётся BLE
            do {
                let listener = try NetworkListener(
                    for: .wifiAware(.connecting(to: service,
                                                from: .allPairedDevices))) {
                    TCP()
                }
                try await listener.run { connection in
                    await self?.serve(connection)
                }
            } catch {
                TransportDiary.note("[рядом/wifi] слушатель не поднялся: \(error)")
            }
        }
        // и одновременно ищем чужие — роль в паре заранее неизвестна
        browserTask = Task { [weak self] in
            guard let service = WASubscribableService.allServices[Self.serviceName]
            else { return }
            do {
                let browser = NetworkBrowser(
                    for: .wifiAware(.connecting(to: .allPairedDevices,
                                                from: service)))
                try await browser.run { endpoints in
                    for endpoint in endpoints {
                        Task { [weak self] in
                            let connection = NetworkConnection(to: endpoint) {
                                TCP()
                            }
                            await self?.serve(connection)
                        }
                    }
                }
            } catch {
                TransportDiary.note("[рядом/wifi] поиск не поднялся: \(error)")
            }
        }
    }

    func stop() {
        listenerTask?.cancel()
        browserTask?.cancel()
        listenerTask = nil
        browserTask = nil
        lock.lock()
        outbound.removeAll()
        peerCount = 0
        lock.unlock()
        onPeersChanged?(0)
    }

    /// Обслуживание одного соединения: приём кадров до обрыва.
    private func serve(_ connection: NetworkConnection<TCP>) async {
        let id = UUID()
        let send: @Sendable ([UInt8]) -> Void = { packet in
            Task {
                let length = UInt32(packet.count)
                var frame = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF),
                             UInt8((length >> 16) & 0xFF),
                             UInt8((length >> 24) & 0xFF)]
                frame += packet
                try? await connection.send(Data(frame))
            }
        }
        lock.lock()
        outbound[id] = send
        peerCount = outbound.count
        let count = peerCount
        lock.unlock()
        onPeersChanged?(count)
        TransportDiary.note("[рядом/wifi] собеседник на связи: \(count)")

        defer {
            lock.lock()
            outbound[id] = nil
            peerCount = outbound.count
            let left = peerCount
            lock.unlock()
            onPeersChanged?(left)
        }

        while !Task.isCancelled {
            do {
                let header = try await connection.receive(exactly: 4)
                let bytes = [UInt8](header.content)
                let length = Int(bytes[0]) | Int(bytes[1]) << 8
                    | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
                guard length > 0, length <= 64 * 1024 else { return }
                let body = try await connection.receive(exactly: length)
                onReceive?([UInt8](body.content))
            } catch {
                return   // обрыв — молча, канал поднимется снова сам
            }
        }
    }

    /// Веером всем соседям этого канала; успех — если было кому отдать.
    func send(_ packet: [UInt8]) -> Bool {
        lock.lock()
        let targets = Array(outbound.values)
        lock.unlock()
        guard !targets.isEmpty else { return false }
        for target in targets { target(packet) }
        return true
    }
}
