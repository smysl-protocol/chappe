import Foundation

// ============================================================================
// B3: стрим-ассемблер FRAG2 (шов, подпись владельца 11.08).
//
// Конвертная половина сборки: куски группируются по msgID, непрерывный
// префикс потока выдаётся ПО МЕРЕ прихода (несёт рацию фазы C).
// ВАЖНО (задача 2 транспорта): выдаваемый префикс — байты СОБИРАЕМОГО
// ПОТОКА, то есть шифртекста; плейнтекст не покидает конверт до
// схождения AEAD — стрим-выдачу подключает только голосовой конвейер
// фазы C (он режет звук на свои AEAD-порции), текст всплывает целиком.
//
// Правила согласованности (задача 1 транспорта, здесь их механика):
// все куски одного msgID обязаны нести одинаковые total и msg_len —
// несходящийся кадр отбрасывается ОШИБКОЙ, сборка живёт (остаточный
// пункт владельца: инъекция под msgID не хоронит сообщение); собранная
// длина обязана равняться msg_len. Буфер ленивый: растёт по приходу,
// предвыделения по msg_len нет. Политика таймаутов — снаружи (now:),
// как у Reassembler v0 §7.
// ============================================================================

nonisolated final class Frag2Assembler {

    struct Emission: Equatable {
        /// Очередные байты непрерывного префикса потока (пусто, если
        /// пришедший кусок дырку не закрыл).
        var newBytes: [UInt8]
        var completed: Bool
        /// Готовый поток целиком — только при completed.
        var stream: [UInt8]?
    }

    private struct Pending {
        let total: Int
        let msgLen: Int
        /// Куски впереди непрерывного префикса (ленивый буфер).
        var parts: [Int: [UInt8]]
        /// Сколько кусков уже выдано префиксом.
        var emitted = 0
        /// Выданный префикс — копится для финальной выдачи целиком.
        var out: [UInt8] = []
        let born: Double
    }

    private let timeout: Double
    private var pending: [UInt16: Pending] = [:]

    init(timeout: Double = Envelope.reassemblyTimeout) {
        self.timeout = timeout
    }

    var pendingCount: Int { pending.count }

    /// Принимает кусок. Бросает на несходящемся кадре (кадр отброшен,
    /// сборка ЖИВЁТ) и на несошедшейся итоговой длине (сборка умирает).
    func add(msgID: UInt16, index: Int, total: Int, msgLen: Int,
             chunk: [UInt8], now: Double = 0.0) throws -> Emission {
        purge(now: now)
        guard total >= 1, total <= EnvelopeV2.frag2MaxTotal,
              index >= 0, index < total,
              msgLen >= 0, msgLen <= EnvelopeV2.frag2MsgLenCap else {
            throw EnvelopeError.badValue("сборка FRAG2: недопустимый блок")
        }

        var rec = pending[msgID] ?? Pending(total: total, msgLen: msgLen,
                                            parts: [:], born: now)
        guard total == rec.total, msgLen == rec.msgLen else {
            throw EnvelopeError.malformed(String(
                format: "FRAG2 msg_id=0x%04X: кадр не сходится по "
                    + "total/msg_len (%d/%d против %d/%d) — отброшен",
                msgID, total, msgLen, rec.total, rec.msgLen))
        }
        // дубликат и уже выданное префиксом — молча игнорируются
        if index >= rec.emitted, rec.parts[index] == nil {
            rec.parts[index] = chunk
        }

        // выдача непрерывного префикса; выданное освобождает буфер
        var newBytes: [UInt8] = []
        while let next = rec.parts[rec.emitted] {
            newBytes += next
            rec.out += next
            rec.parts[rec.emitted] = nil
            rec.emitted += 1
        }

        guard rec.emitted == rec.total else {
            pending[msgID] = rec
            return Emission(newBytes: newBytes, completed: false,
                            stream: nil)
        }
        pending[msgID] = nil
        guard rec.out.count == rec.msgLen else {
            throw EnvelopeError.malformed(String(
                format: "FRAG2 msg_id=0x%04X: собрано %d Б, заявлено %d",
                msgID, rec.out.count, rec.msgLen))
        }
        return Emission(newBytes: newBytes, completed: true,
                        stream: rec.out)
    }

    private func purge(now: Double) {
        pending = pending.filter { now - $0.value.born <= timeout }
    }
}
