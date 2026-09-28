import Foundation

// ============================================================================
// ШОВ КАРТЫ С ТРАНСПОРТОМ (п.5 плана 29.07). Единственный файл, который
// знает одновременно про слой карты и про конверт/очередь/доставку.
//
// Контракт на будущее: запечатывание LOCATION и метка времени отправки
// приедут «семантической сессией» одним подъёмом версии конверта —
// тогда меняется ТОЛЬКО этот файл: send() начнёт заворачивать payload
// в sealed-формат, ingest() — разворачивать и атрибутировать по ключу
// отправителя. Конверт, кодек и словарь отсюда не редактируются.
//
// Исходящее: DisclosedPosition (создать может только политика WP4) →
// канонический LOCATION-пакет (Envelope §5, ТВ-2б) → очередь → толчок
// доставки. Другой дороги координаты в очередь нет.
//
// Входящее: сырой LOCATION-пакет от DeliveryManager. Wire-формат v0 не
// несёт отправителя (открытые байты §5) — атрибуция только при
// единственном контакте (полевая конфигурация 1:1), иначе пакет честно
// отбрасывается, а не приписывается наугад.
// ============================================================================

@MainActor
final class LocationTransport {

    static let shared = LocationTransport()

    /// Единственная дорога координаты в исходящую очередь.
    /// Возвращает false, если пакет не собрался/не встал в очередь.
    ///
    /// Рев B (подпись шва, п.6): позиция едет ВНУТРЕННИМ кодеком 7
    /// sealed-путём (5/6) — наблюдатель не отличает её от текста;
    /// отправка открытым классом 0x5 ПРЕКРАЩЕНА. Собеседник без
    /// подтверждённого рев B позиций не получает (честный отказ в
    /// дневник) — открытый канал утечки не возвращаем.
    @discardableResult
    func send(_ disclosed: DisclosedPosition, entryID: UUID = UUID(),
              pushImmediately: Bool = true) -> Bool {
        guard PeerCaps.load(contactID: disclosed.contactID).revB,
              let contact = ContactStore.load()
                  .first(where: { $0.id == disclosed.contactID }) else {
            TransportDiary.note("[гео] позиция НЕ отправлена: собеседник "
                + "не подтвердил рев B (открытый 0x5 прекращён)")
            return false
        }
        let precision: Int = switch disclosed.precision {
        case .exact: 0
        case .coarse(let len): len
        }
        guard let payload = try? PositionPayload(
            precision: precision, lat: disclosed.lat, lon: disclosed.lon,
            measuredAt: UInt32(clamping:
                Int(disclosed.measuredAt.timeIntervalSince1970))).encode(),
            payload.first == EnvelopeRevB.codecPosition else { return false }
        // маячок не аккается (вытесняется следующим) и вытесняет
        // недоставленный старый — обе политики в enqueueSealed
        guard (try? Outbox.enqueueSealed(
            innerCodec: EnvelopeRevB.codecPosition,
            data: Array(payload.dropFirst()),
            to: contact, entryID: entryID,
            wantAck: false, positionBeacon: true)) != nil else { return false }
        if pushImmediately { DeliveryManager.shared.pushQueue() }
        return true
    }

    /// Пакет в очереди — LOCATION? (по классу в заголовке первого пакета)
    private func isLocationPacket(_ item: Outbox.QueuedMessage) -> Bool {
        guard let hex = item.packetsHex.first else { return false }
        let packet = Outbox.bytes(fromHex: hex)
        guard let header = try? Envelope.decodeHeader(packet) else { return false }
        return header.msgClass == Envelope.classLocation
    }

    /// Единственная дорога принятой позиции в хранилище.
    /// Возвращает true, если позиция атрибутирована и сохранена.
    @discardableResult
    func ingest(packet: [UInt8],
                header: (msgClass: UInt8, flags: UInt8, msgID: UInt16),
                receivedAt: Date = Date(),
                contacts: [Contact]? = nil,
                store: PeerPositionStore? = nil) -> Bool {
        guard let loc = try? LocationMessage.decodeBody(flags: header.flags,
                                                        msgID: header.msgID,
                                                        packet: packet),
              let lat = loc.lat, let lon = loc.lon else { return false }
        let known = contacts ?? ContactStore.load()
        guard known.count == 1 else { return false }
        return (store ?? PeerPositionStore.shared)
            .ingest(contactID: known[0].id, lat: lat, lon: lon,
                    receivedAt: receivedAt)
    }
}
