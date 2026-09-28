import Foundation
import Network

// ============================================================================
// Транспорт (веха, фаза 3; transport_manager.md §1).
//
// TransportLink — абстракция канала: шлёт и принимает ТОЛЬКО готовые
// envelope-блобы. Никакого плейнтекста на проводе — это репетиция LoRa.
//  - DemoLoopback: прежнее поведение демо-чата («узлов нет», очередь копит);
//  - LanLink: TCP в локальной сети (симулятор на Маке ↔ телефон в одном
//    Wi-Fi). Слушаем NWListener на порту 47474; отправка — короткое
//    NWConnection к peer. Framing: [длина u32 LE][блоб].
// ============================================================================

nonisolated protocol TransportLink: AnyObject {
    var onReceive: (@Sendable ([UInt8]) -> Void)? { get set }
    func start()
    func stop()
    /// completion(true) — пакет реально принят стеком получателя
    /// (TCP-запись прошла); false — канал мёртв, нужен повтор.
    func send(_ packet: [UInt8], toHost host: String,
              completion: @escaping @Sendable (Bool) -> Void)
}

extension TransportLink {
    /// Отправка без интереса к исходу (ack'и: потеряется — отправитель
    /// повторит сообщение, ack уйдёт снова).
    func send(_ packet: [UInt8], toHost host: String) {
        send(packet, toHost: host) { _ in }
    }
}

/// Демо: канал никуда не ведёт — очередь честно копит («узлов нет»).
nonisolated final class DemoLoopback: TransportLink, @unchecked Sendable {
    var onReceive: (@Sendable ([UInt8]) -> Void)?
    func start() {}
    func stop() {}
    func send(_ packet: [UInt8], toHost host: String,
              completion: @escaping @Sendable (Bool) -> Void) {
        completion(false)   // честно: в демо ничего никуда не уходит
    }
}

/// TCP-линк локальной сети. Порт фиксированный: обе стороны слушают
/// 47474; discovery пока ручной (IP собеседника в Dev).
///
/// nonisolated + всё мутабельное строго на своей очереди (стенд ×51,
/// 09.08: 49 крэшей тест-хоста; доминирующая подпись — джоба
/// изолированного deinit на главной очереди сносит объект с битым isa,
/// один репорт назвал жертву: LanLink.__isolated_deallocating_deinit.
/// Прежний класс не был помечен nonisolated — под MainActor-по-
/// умолчанию его деаллокация ехала отдельной джобой, а
/// @unchecked Sendable при несинхронизированных var (listener,
/// onReceive) был обещанием без замка: главный поток и сетевая очередь
/// трогали их наперегонки. Образец — BleLink: nonisolated, состояние
/// на своей очереди, в крэшах стенда не замечен.)
nonisolated final class LanLink: TransportLink, @unchecked Sendable {

    static let defaultPort: UInt16 = 47474
    let port: UInt16
    private let queue = DispatchQueue(label: "chappe.lanlink")
    /// Оба поля — ТОЛЬКО на queue; изнутри колбэков читать напрямую
    /// (_onReceive), снаружи — через свойство с замком.
    private var _onReceive: (@Sendable ([UInt8]) -> Void)?
    private var listener: NWListener?

    var onReceive: (@Sendable ([UInt8]) -> Void)? {
        get { queue.sync { _onReceive } }
        set { queue.sync { _onReceive = newValue } }
    }

    init(port: UInt16 = LanLink.defaultPort) {
        self.port = port
    }

    func start() {
        queue.sync {
            stopLocked()
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true   // рестарт без «in use»
            guard let listener = try? NWListener(
                using: params, on: NWEndpoint.Port(rawValue: port)!) else {
                print("[lan] listener не поднялся")
                return
            }
            listener.newConnectionHandler = { [weak self] connection in
                // хендлер уже на queue (listener.start(queue:))
                connection.start(queue: self?.queue ?? .global())
                self?.receiveFrames(connection, buffer: [])
            }
            listener.stateUpdateHandler = { state in
                print("[lan] listener: \(state)")
            }
            listener.start(queue: queue)
            self.listener = listener
            print("[lan] стартую listener :\(port)")
        }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
    }

    /// Кадры: [длина u32 LE][блоб] — копим и выдаём по мере полноты.
    private func receiveFrames(_ connection: NWConnection, buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(contentsOf: data) }
            while buffer.count >= 4 {
                let length = Int(buffer[0]) | Int(buffer[1]) << 8
                           | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
                guard length > 0, length <= 8192,
                      buffer.count >= 4 + length else { break }
                let packet = Array(buffer[4..<(4 + length)])
                buffer.removeFirst(4 + length)
                // напрямую: мы уже на queue, свойство бы село в deadlock
                self?._onReceive?(packet)
            }
            if error == nil && !done {
                self?.receiveFrames(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    func send(_ packet: [UInt8], toHost host: String,
              completion: @escaping @Sendable (Bool) -> Void) {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let once = NetProbeOnce()
        // таймаут: соединение зависло (чёрная дыра) — считаем неудачей
        queue.asyncAfter(deadline: .now() + 5) {
            once.run { completion(false) }
            connection.cancel()
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .waiting:
                // waiting = адресат недостижим (отказ/нет маршрута) —
                // не ждём сеть, честно докладываем и уходим на повтор
                once.run { completion(false) }
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        let length = UInt32(packet.count)
        let frame = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF),
                     UInt8((length >> 16) & 0xFF), UInt8((length >> 24) & 0xFF)]
                    + packet
        connection.send(content: Data(frame),
                        completion: .contentProcessed { error in
            once.run { completion(error == nil) }
            // дать кадру дойти и закрыть со стороны отправителя
            connection.cancel()
        })
    }
}

// MARK: - Мой IP (для настройки peer с другой стороны)

nonisolated enum NetInfo {
    /// IPv4 первого не-loopback интерфейса (en0 приоритетно).
    static func myIPv4() -> String? {
        var addresses: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append((String(cString: ptr.pointee.ifa_name),
                                  String(cString: host)))
            }
        }
        return (addresses.first { $0.name == "en0" } ?? addresses.first)?.ip
    }
}

/// Диагностика связности: TCP-проба до host:port с текстом исхода.
nonisolated enum NetProbe {
    static func tcp(host: String, port: UInt16) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = NetProbeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: "ready") }
                    connection.cancel()
                case .failed(let error):
                    once.run { continuation.resume(
                        returning: "failed: \(error)") }
                case .waiting(let error):
                    once.run { continuation.resume(
                        returning: "waiting: \(error)") }
                    connection.cancel()
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }
}

private nonisolated final class NetProbeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { body() }
    }
}
