import Foundation
import Testing
import Security
@testable import Chappe

// ============================================================================
// WP3 (бриф 05.08): хранение ключей на устройстве.
// 1. Keychain-записи личности — ThisDeviceOnly: приватный ключ и сид
//    не мигрируют в резервные копии (iCloud/локальные); явный путь
//    переноса — бумажный сид, других не задумано.
// 2. Состояние рэтчета не попадает в iCloud-бэкап: восстановленное из
//    бэкапа старое состояние — рассинхрон и откат forward secrecy.
// Замки: слом (возврат AfterFirstUnlock без ThisDeviceOnly, снятие
// isExcludedFromBackup) красит тесты.
// ============================================================================

struct KeyStorageTests {

    @Test("ключи личности в Keychain — ThisDeviceOnly")
    func identityKeychainIsThisDeviceOnly() {
        // личность существует (создаётся при первом обращении)
        #expect(Identity.publicKey() != nil)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.chappe.app.identity",
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        #expect(status == errSecSuccess, "записи личности не найдены")
        let items = out as? [[CFString: Any]] ?? []
        #expect(!items.isEmpty)
        for item in items {
            let accessible = item[kSecAttrAccessible] as? String
            let account = (item[kSecAttrAccount] as? String) ?? "?"
            #expect(accessible ==
                    (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
                    "запись «\(account)» мигрирует в бэкап: \(accessible ?? "nil")")
        }
    }

    @Test("каталог рэтчета исключён из бэкапа")
    func ratchetDirIsExcludedFromBackup() throws {
        // сохранение хотя бы одного состояния создаёт каталог с флагом
        let contactID = "WP3TEST"
        let epoch = RatchetEpoch(seed: (0..<32).map { _ in
            UInt8.random(in: 0...255) }, iAmInitiator: true)
        RatchetStore.save(epoch, contactID: contactID)
        defer { RatchetStore.drop(contactID: contactID) }

        let dir = try RatchetStore.url(contactID: contactID)
            .deletingLastPathComponent()
        let values = try dir.resourceValues(
            forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true,
                "каталог рэтчета уедет в iCloud-бэкап")
    }
}
