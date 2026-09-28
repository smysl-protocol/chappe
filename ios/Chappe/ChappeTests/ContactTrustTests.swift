//
//  ContactTrustTests.swift
//  RMTests
//
//  Импорт карточки из галереи (30.07.2026): схема rm://contact/,
//  распознавание Vision локально, несколько QR → выбор, чужой QR →
//  честная ошибка. Доверие: импорт всегда «непроверен», «проверен» —
//  только после сверки, повторный импорт сверку не сбивает.
//

import Foundation
import Testing
import CryptoKit
import UIKit
@testable import Chappe

struct ContactSchemeTests {

    private func makePayload(name: String = "Тест") -> String {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        let json = ["v": 1, "name": name,
                    "pub": key.rawRepresentation.base64EncodedString()] as [String: Any]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return data.base64EncodedString()
    }

    /// Разбор принимает и rm://contact/…, и старый голый base64.
    @Test func parseAcceptsSchemeAndBareBase64() {
        let base64 = makePayload()
        #expect(ContactStore.parse(base64) != nil)
        #expect(ContactStore.parse(ContactStore.scheme + base64) != nil)
        #expect(ContactStore.parse("RM://CONTACT/" + base64) != nil,
                "регистр схемы не важен")
    }

    /// Чужая схема и мусор — честный nil, не «почти контакт».
    @Test func parseRejectsForeignPayloads() {
        #expect(ContactStore.parse("https://example.com/qr") == nil)
        #expect(ContactStore.parse("подписывайся на канал") == nil)
        #expect(ContactStore.parse("rm://contact/не-base64!") == nil)
    }

    /// Мой QR несёт схему.
    @Test @MainActor func myPayloadTextCarriesScheme() {
        if let text = ContactStore.myPayloadText() {
            #expect(text.hasPrefix(ContactStore.scheme))
            #expect(ContactStore.parse(text) != nil)
        }
        // nil допустим только если Keychain не отдал ключ (не в тестах)
    }
}

@MainActor
struct GalleryDecodeTests {

    /// QR с тихой зоной: спека QR требует белое поле ≥4 модулей вокруг
    /// кода, без него распознавание вправе не сработать. Голый вывод
    /// CIQRCodeGenerator поля не несёт — в реальных скриншотах оно
    /// есть всегда, здесь добавляем сами.
    private func qrImage(_ text: String) -> UIImage {
        let raw = MyQRView.qrImage(text)!
        let margin: CGFloat = 48
        let size = CGSize(width: raw.size.width + margin * 2,
                          height: raw.size.height + margin * 2)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            raw.draw(at: CGPoint(x: margin, y: margin))
        }
    }

    private func makeCardText(name: String) -> String {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        let json = ["v": 1, "name": name,
                    "pub": key.rawRepresentation.base64EncodedString()] as [String: Any]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return ContactStore.scheme + data.base64EncodedString()
    }

    /// Одна валидная карточка: распознана и помечена НЕПРОВЕРЕННОЙ —
    /// канал (картинка) мог быть подменён по дороге.
    @Test func singleCardIsRecognizedAndMarkedUnverified() {
        let outcome = GalleryQRDecoder.decode(
            image: qrImage(makeCardText(name: "Анна")))
        guard case .contacts(let contacts) = outcome else {
            Issue.record("ожидалась карточка, получено \(outcome)")
            return
        }
        #expect(contacts.count == 1)
        #expect(contacts[0].name == "Анна")
        #expect(contacts[0].isUnverified,
                "импорт из галереи всегда непроверенный")
    }

    /// Чужой QR (сайт) — честная ошибка «не наша схема», не тишина.
    @Test func foreignQRIsHonestError() {
        let outcome = GalleryQRDecoder.decode(
            image: qrImage("https://example.com/menu"))
        #expect(outcome == .foreignQR(count: 1))
        #expect(GalleryQRDecoder.errorText(for: outcome)?
            .contains("rm://") == true)
    }

    /// Картинка без QR — честная ошибка.
    @Test func imageWithoutQRIsHonestError() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200,
                                                            height: 200))
        let blank = renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let outcome = GalleryQRDecoder.decode(image: blank)
        #expect(outcome == .noQR)
        #expect(GalleryQRDecoder.errorText(for: outcome) != nil)
    }

    /// Два QR на одной картинке → обе карточки наружу (выбор за
    /// человеком, первую молча не берём — это проверяет UI-слой,
    /// здесь — что декодер не теряет вторую).
    @Test func twoQRCodesYieldBothCandidates() {
        let left = qrImage(makeCardText(name: "Анна"))
        let right = qrImage(makeCardText(name: "Борис"))
        let size = CGSize(width: left.size.width + right.size.width + 60,
                          height: max(left.size.height, right.size.height) + 40)
        let renderer = UIGraphicsImageRenderer(size: size)
        let combined = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            left.draw(at: CGPoint(x: 20, y: 20))
            right.draw(at: CGPoint(x: left.size.width + 40, y: 20))
        }
        let outcome = GalleryQRDecoder.decode(image: combined)
        guard case .contacts(let contacts) = outcome else {
            Issue.record("ожидались две карточки, получено \(outcome)")
            return
        }
        #expect(contacts.count == 2)
        let names = Set(contacts.map { $0.name })
        #expect(names == ["Анна", "Борис"])
        let allUnverified = contacts.allSatisfy { $0.isUnverified }
        #expect(allUnverified)
    }
}

struct ContactTrustTests {

    /// Свой корень хранилища на вызов (тест-инфра, заказ владельца
    /// 10.08): вместо снимка/восстановления ОБЩЕГО файла — собственный
    /// каталог через ContactStore.$testStorageRoot. Общий contacts.json
    /// кусал трижды: чистильщики и добавители параллельных сюит
    /// перетирали друг друга (lost update), краш-индекс 09.08 валил
    /// весь тест-хост (363 «провала» одним крэшем).
    private func withCleanStore(_ body: () throws -> Void) rethrows {
        try ContactStore.$testStorageRoot.withValue(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("trust-\(UUID().uuidString)")) {
            try body()
        }
    }

    private func makeContact(verified: Bool?) -> Contact {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        return Contact(id: Identity.fingerprint(of: key), name: "Тест",
                       publicKeyBase64: key.rawRepresentation
                           .base64EncodedString(),
                       addedAt: Date(), verified: verified)
    }

    /// «Проверен» ставится только явной сверкой; повторный импорт
    /// той же карточки (тот же ключ) сверку НЕ сбивает.
    @Test func verificationOnlyByExplicitCheckAndNeverDowngraded() throws {
        try withCleanStore {
            var contact = makeContact(verified: false)
            let id = contact.id
            // поиск по id, не load()[0]: contacts.json общий на весь
            // прогон, параллельная сюита успевает его переписать —
            // сабскрипт валил краш-индексом ВЕСЬ тест-хост (363
            // «провала» одним махом, прогон 09.08 16:55)
            func mine() throws -> Contact {
                try #require(ContactStore.load().first { $0.id == id },
                             "контакт теста пропал из общего хранилища")
            }
            ContactStore.upsert(contact)
            let fresh = try mine()
            #expect(fresh.isUnverified)

            // сверка отпечатка — явное действие
            ContactStore.markVerified(id: id)
            let checked = try mine()
            #expect(checked.verified == true)

            // повторный импорт из галереи не понижает доверие:
            // id = отпечаток ключа, ключ тот же
            contact.verified = false
            ContactStore.upsert(contact)
            let after = try mine()
            #expect(after.verified == true,
                    "импорт не должен сбивать сверенное доверие")
        }
    }

    /// Старые контакты без поля verified читаются без пометки.
    @Test func legacyContactsDecodeWithoutBadge() throws {
        let legacy = #"[{"id":"ABCDEFGH","name":"Старый","publicKeyBase64":"AA==","addedAt":770000000}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let contacts = try decoder.decode([Contact].self,
                                          from: Data(legacy.utf8))
        #expect(contacts[0].verified == nil)
        #expect(!contacts[0].isUnverified)
    }
}
