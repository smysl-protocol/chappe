import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// А1 (09.08): замер латентности пути отправки ПО СТАДИЯМ — на Release,
// на живом устройстве (правило 7: перф только Release; симулятор не
// годится). Запуск:
//   xcodebuild test -configuration Release -destination "platform=iOS,..."
//     -only-testing:ChappeTests/SendLatencyPerfTests ENABLE_TESTABILITY=YES
// Отчёт печатается строками «[замер]» — снять из xcresult/консоли.
// Без модели на устройстве тест честно скипается — замер без модельной
// стадии был бы враньём.
// ============================================================================

struct SendLatencyPerfTests {

    private func ms(_ from: ContinuousClock.Instant,
                    _ clock: ContinuousClock) -> Double {
        let parts = (clock.now - from).components
        return Double(parts.seconds) * 1000
             + Double(parts.attoseconds) / 1e15
    }

    @Test("стадии отправки типового сообщения, мс",
          .timeLimit(.minutes(10)))
    @MainActor
    func stagesOnTypicalMessage() async throws {
        let text = "встречу перенесли на завтра на семь вечера у моста"
        let clock = ContinuousClock()

        // Стадия 0: гейты (политика пивота + пред-детект) — чистые
        var t = clock.now
        let worth = SendPolicy.pivotWorthRunning(
            hasContact: true, loRaConfigured: true)
        let gateMs = ms(t, clock)
        print("[замер] гейт политики: \(String(format: "%.3f", gateMs)) мс "
              + "(worth=\(worth))")

        guard ModelScheduler.isLocalProviderActive(), RMCodec.shared != nil
        else {
            // это замерный стенд, не замок: без модели таблица стадий
            // невозможна — говорим и выходим (гонять на устройстве
            // с установленным помощником)
            print("[замер] модель/словарь недоступны — замер пропущен")
            return
        }

        // Стадия 1: модель + Smysl-кодирование (SemanticEncoder целиком),
        // холодный проход (включает подъём модели) и тёплый
        t = clock.now
        let cold = await SemanticEncoder.prepare(russian: text)
        let coldMs = ms(t, clock)
        print("[замер] конвейер холодный: \(String(format: "%.0f", coldMs)) мс "
              + "(итог: \(outcomeName(cold)))")

        t = clock.now
        let warm = await SemanticEncoder.prepare(russian: text)
        let warmMs = ms(t, clock)
        print("[замер] конвейер тёплый: \(String(format: "%.0f", warmMs)) мс "
              + "(итог: \(outcomeName(warm)))")

        // Стадия 2: чистое Smysl-кодирование пивота (без модели)
        if case .semantic(let encoded) = warm {
            t = clock.now
            _ = try? RMCodec.shared?.encode(
                PivotMatcher.shared?.units(fromPivot: encoded.pivot) ?? [])
            print("[замер] кодек Smysl: "
                  + String(format: "%.2f", ms(t, clock)) + " мс")
        }

        // Стадия 3: быстрый путь для сравнения — текстовый кодек
        t = clock.now
        let (codec, data) = TextCodec.best(text)
        let textCodecMs = ms(t, clock)
        print("[замер] текстовый кодек: "
              + String(format: "%.2f", textCodecMs)
              + " мс (кодек \(codec), \(data.count) Б)")

        // Стадия 4: хендшейк + шифр + фрагментация (enqueueSealed):
        // первый раз (рукопожатие) и второй (сессия)
        let peer = Curve25519.KeyAgreement.PrivateKey()
        let contact = Contact(
            id: Identity.fingerprint(of: peer.publicKey),
            name: "Замер-латентности",
            publicKeyBase64: peer.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: Date())
        defer {
            RatchetStore.drop(contactID: contact.id)
            Outbox.saveQueueRaw(Outbox.loadQueueRaw()
                .filter { $0.contactID != contact.id })
        }
        t = clock.now
        let first = try Outbox.enqueueSealed(innerCodec: codec, data: data,
                                             to: contact, entryID: UUID())
        let handshakeMs = ms(t, clock)
        print("[замер] шифр+хендшейк+фрагментация (первое): "
              + String(format: "%.2f", handshakeMs)
              + " мс (\(first.packetsHex.count) пакетов, "
              + "\(first.totalBytes) Б)")
        t = clock.now
        _ = try Outbox.enqueueSealed(innerCodec: codec, data: data,
                                     to: contact, entryID: UUID())
        print("[замер] шифр+сессия+фрагментация (второе): "
              + String(format: "%.2f", ms(t, clock)) + " мс")

        // Итог быстрого пути без модели: гейт + текстовый кодек + конверт
        let fastTotal = gateMs + textCodecMs + handshakeMs
        print("[замер] ИТОГО быстрый путь (без модели): "
              + String(format: "%.1f", fastTotal) + " мс")
        // Замок А1: быстрый транспорт обязан укладываться в 500 мс
        // (замер 09.08: 14,5 мс — запас 34×). Слом: загнать быстрый
        // путь в модельный конвейер — красный и здесь, и в
        // SendPolicyTests (сосед не смеет включать кодек).
        #expect(fastTotal < 500, Comment(rawValue:
                "быстрый путь дороже 500 мс: \(fastTotal) мс"))
    }

    private func outcomeName(_ o: SemanticEncoder.Outcome) -> String {
        switch o {
        case .semantic(let e): "semantic, пивот «\(e.pivot.prefix(40))…»"
        case .text(let reason, _): "text (\(reason))"
        }
    }
}
