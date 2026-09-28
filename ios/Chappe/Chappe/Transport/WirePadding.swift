import Foundation

// ============================================================================
// Паддинг кадров в бакеты (№7 реестра, решение владельца 09.08).
//
// Условный по транспорту: быстрые пути (интернет-релей, BLE, Wi-Fi
// Aware, локальная сеть) прячут длину кадра, добивая его случайными
// байтами до кратного бакету размера; LoRa НЕ паддится — там каждый
// байт стоит эфирного времени, и паддинг с кодеком так не пересекаются.
//
// ЧЕСТНАЯ ГРАНИЦА: паддинг закрывает только ДЛИНУ кадра. Тайминги
// отправки и частоту сообщений он не прячет — наблюдатель канала
// по-прежнему видит, КОГДА и КАК ЧАСТО стороны говорят.
//
// Обёртка самоописываемая: [маркер 0xAD][длина u16 LE][кадр][случайный
// хвост]. Маркер несёт старший ниббл 0xA — разборщики v1 (0x1X) и
// v2 (0x2X) на нём честно отказывают («неизвестная версия формата»),
// как v2-пакет на старом бинарнике: сборка 6 обёрнутый кадр молча
// отбросит, не упав (то же штатное поведение, что WP3).
// ============================================================================

nonisolated enum WirePadding {

    /// Маркер обёртки. Старший ниббл ≥ 3 — не спутается с v1/v2.
    static let marker: UInt8 = 0xAD
    /// [маркер][длина u16 LE] перед кадром.
    static let headerLength = 3
    /// Бакет: все типовые кадры (≤ Envelope.maxPayload = 200 Б плюс
    /// обёртка) ложатся в один бакет — наблюдатель видит константу.
    /// Кратность оставлена под FRAG2 (B3), когда кадры вырастут.
    static let bucket = 256

    /// Паддинг платится только там, где байты дёшевы.
    static func applies(toTransport kind: String) -> Bool {
        kind != "mesh"   // LoRa: байты дороже скрытия длины
    }

    /// Обернуть кадр: длина итога кратна бакету. Кадр длиннее u16
    /// не оборачивается (сегодня таких нет; FRAG2 принесёт свои рамки).
    static func pad(_ packet: [UInt8]) -> [UInt8] {
        guard packet.count <= 0xFFFF else { return packet }
        var frame = [marker,
                     UInt8(packet.count & 0xFF),
                     UInt8(packet.count >> 8)]
        frame += packet
        let target = ((frame.count + bucket - 1) / bucket) * bucket
        // хвост случайный: детерминированный был бы вторым каналом
        frame += (frame.count..<target).map { _ in
            UInt8.random(in: .min ... .max)
        }
        return frame
    }

    /// Снять обёртку. nil — это не обёртка или она битая (кадр короче
    /// заявленной длины); хвост отбрасывается по длине из заголовка.
    static func unwrap(_ blob: [UInt8]) -> [UInt8]? {
        guard blob.count >= headerLength, blob[0] == marker else {
            return nil
        }
        let length = Int(blob[1]) | Int(blob[2]) << 8
        guard blob.count >= headerLength + length else { return nil }
        return Array(blob[headerLength..<headerLength + length])
    }

    /// Кадр в канал данного транспорта: быстрый — в бакете, LoRa — голый.
    static func outbound(_ packet: [UInt8], transport kind: String)
        -> [UInt8] {
        applies(toTransport: kind) ? pad(packet) : packet
    }
}
