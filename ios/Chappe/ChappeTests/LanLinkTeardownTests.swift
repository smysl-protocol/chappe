import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Детерминированный замок гонки сноса LanLink (А4, 09.08).
//
// Вместо «прогнать ×51 и посчитать крэши»: порядок форсируется —
// держим ссылку → дёргаем listener живым loopback-трафиком → отпускаем
// последнюю ссылку РОВНО в момент, когда колбэк приёма стоит на
// очереди линка, и параллельно молотим onReceive с главного потока
// (несинхронизированная var-замыкание — прямое место гонки старого
// кода). До починки (изолированный deinit + поля без замка под
// @unchecked Sendable) это окно роняло хост SIGSEGV (49 крэшей стенда
// 08-09.08); с починкой (nonisolated + состояние на своей очереди)
// прогон обязан быть зелёным.
// ============================================================================

struct LanLinkTeardownTests {

    /// Свободный TCP-порт от системы (bind :0 → getsockname).
    /// Фиксированные 52000+ кусались: порт держал посторонний процесс
    /// мака (симулятор делит его сетевой стек), listener падал
    /// «Address already in use», и тест висел в ожидании кадра
    /// (прогоны 10.08). Порт выделяет ОС — коллизий нет по построению.
    private func freePort() -> UInt16 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, len)
            }
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    @Test("снос под огнём: отпускаем ссылку в момент колбэка приёма",
          .timeLimit(.minutes(2)))
    func teardownUnderReceiveFire() async throws {
        for round in 0..<8 {
            let port = freePort()
            var link: LanLink? = LanLink(port: port)
            let gotFrame = AsyncStream<Void>.makeStream()
            link?.onReceive = { _ in
                gotFrame.continuation.yield()
            }
            link?.start()
            try await Task.sleep(for: .milliseconds(30))   // listener поднялся

            // отправитель шлёт кадры в порт — колбэки приёма занимают
            // очередь линка
            let sender = LanLink(port: port)
            let frame: [UInt8] = Array(repeating: 0xAB, count: 900)
            for _ in 0..<4 {
                sender.send(frame, toHost: "127.0.0.1") { _ in }
            }

            // Двое молотят var-замыкание НАПЕРЕГОНКИ: писатель ставит
            // новое (release старого контекста), читатель грузит и
            // ретейнит — в старом коде это несинхронизированный доступ
            // к сильной ссылке (@unchecked Sendable без замка): читатель
            // успевает загрузить указатель, писатель освобождает контекст
            // до его retain — пере-освобождение, битый refcount, и крэш
            // всплывает позже — в джобе изолированного deinit (подпись
            // 44 крэшей стенда). Слабые захваты: трэш не держит
            // последнюю сильную ссылку, финальный release — с чужого
            // потока (спелый путь для изолированного deinit).
            // двое писателей и двое читателей — максимум коллизий
            // retain-читателя с release-писателя на одном слове памяти
            let thrashers = (0..<4).map { lane in
                Task.detached { [weak link] in
                    var spins = 0
                    while let alive = link, spins < 150_000 {
                        if lane % 2 == 0 {
                            alive.onReceive = { _ in
                                gotFrame.continuation.yield()
                            }
                        } else {
                            _ = alive.onReceive
                        }
                        spins += 1
                    }
                }
            }

            // дать шторму раскрутиться, дождаться колбэка — и отпустить
            // ссылку посреди него, пока очередь линка крутит приём
            try await Task.sleep(for: .milliseconds(25))
            var iterator = gotFrame.stream.makeAsyncIterator()
            _ = await iterator.next()
            link?.stop()
            link = nil
            for t in thrashers { await t.value }
            gotFrame.continuation.finish()
        }

        // Ядро гонки сноса: ДВА конкурентных stop() на живом listener.
        // В старом коде оба потока без замка исполняли
        // «listener?.cancel(); listener = nil»: два гоняющихся store
        // освобождают ОДИН NWListener дважды — битый refcount, крэш
        // (или клин NW) — тот самый класс 44 крэшей стенда. С починкой
        // stop() сериализован на очереди линка — раунды проходят.
        let core = LanLink(port: freePort())
        for _ in 0..<400 {
            core.start()
            async let a: Void = Task.detached { core.stop() }.value
            async let b: Void = Task.detached { core.stop() }.value
            _ = await (a, b)
        }
        core.stop()
        // живы и не упали — замок держит: крэш класса «битый isa при
        // деаллокации» валит весь хост, зелёным он пройти не может
        #expect(Bool(true))
    }
}
