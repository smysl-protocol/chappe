import SwiftUI
import Network
import DeviceDiscoveryUI
import WiFiAware

// ============================================================================
// Спаривание Wi-Fi Aware, спрятанное в момент знакомства (бриф 07.08).
//
// Почему оно вообще есть. Проверено по SDK iOS 26.5: весь Wi-Fi Aware
// работает ТОЛЬКО со спаренными устройствами (WAPairedDevice; у ошибки
// даже есть отдельный случай noPairedDevices), а спаривание делает
// система своим экраном — тихо, из кода, его выполнить нельзя.
// Единственный способ подсунуть ключ «снаружи» — WASharedSecret —
// выводится ИЗ уже установленного соединения, то есть спаривание не
// заменяет.
//
// Как сделано максимально бесшовно. Спаривание не существует как
// отдельный шаг и не всплывает потом: обе половины поднимаются ровно в
// момент QR-знакомства, когда люди и так стоят рядом с телефонами в
// руках, и после этого не повторяются никогда (access .permanent):
//   - тот, кто ПОКАЗЫВАЕТ карточку, — публикующая сторона: экран
//     «Мой QR» сам поднимает системный экран готовности;
//   - тот, кто СКАНИРУЕТ, — подписчик: сразу после добавления контакта
//     ему показывается системный выбор ближайшего телефона.
// Слова «Wi-Fi Aware», «спаривание», «пиры» человеку не показываются:
// в наших подписях это «знакомство телефонов».
//
// Если что-то из этого не сложилось (старый телефон, отказ, нет радио) —
// связь просто работает через BLE, и человеку об этом не сообщается.
// ============================================================================

@available(iOS 26.0, *)
enum NearbyPairing {

    /// Общий выключатель системного экрана знакомства телефонов.
    ///
    /// Был выключен после полевого отказа 08.08 («Мой QR» ронял
    /// приложение). Корень изолирован стендом 11.08 зондом
    /// --probe-aware: malformed WiFiAwareServices — Publishable/
    /// Subscribable были булевыми, фреймворк требует ПУСТЫЕ СЛОВАРИ
    /// и роняет процесс ассертом на первом касании allServices.
    /// Чек-лист включения пройден: (1) allServices содержит
    /// _chappe-near._tcp живьём (зонд, телефон), (2) entitlement и
    /// WiFiAwareServices — в собранном пакете (codesign + plutil;
    /// замок wifiAwareServicesDeclaredAsDictionaries).
    ///
    /// ВЫКЛЮЧЕНО ОБРАТНО (полевое 12.08): системный экран поднимается
    /// без краша, НО пустой — «Nearby devices will appear here…», Aware-
    /// канал не завершает спаривание, и лишний промежуточный экран на
    /// «Мой QR» только смущает (жалоба владельца). Пока Aware-плечо
    /// реально не заработает, знакомство идёт по BLE («рядом») без
    /// системного экрана. Включать обратно — только с живым каналом.
    static let uiEnabled = false

    /// Поддерживает ли устройство спаривание для нашего сервиса.
    @MainActor
    static var isSupported: Bool {
        guard let service = WAPublishableService
            .allServices[NearbyWiFiChannel.serviceName] else { return false }
        return DDDevicePairingViewController.isSupported(
            .wifiAware(.connecting(to: service, from: .allPairedDevices)))
    }

    /// Уже знакомы телефонами — второй раз показывать нечего.
    static func alreadyPaired() async -> Bool {
        await NearbyWiFiChannel.hasPairedDevices()
    }

    /// Стендовый зонд изоляции краша (11.08): краш-кандидаты по
    /// одному, каждый шаг фиксируется ДО следующего — падение на
    /// шаге N означает, что виновник именно N. Системный экран
    /// НЕ открывается. Запуск: dev-аргумент --probe-aware.
    static func isolationProbe(mark: (String) -> Void) async -> String {
        mark("шаг 1: WAPublishableService.allServices…")
        let pub = WAPublishableService
            .allServices[NearbyWiFiChannel.serviceName] != nil
        mark("шаг 1 ок (publishable=\(pub)); шаг 2: WASubscribableService…")
        let sub = WASubscribableService
            .allServices[NearbyWiFiChannel.serviceName] != nil
        mark("шаг 2 ок (subscribable=\(sub)); шаг 3: DDDevicePairing…")
        let supported = await MainActor.run { isSupported }
        mark("шаг 3 ок (supported=\(supported)); шаг 4: hasPairedDevices…")
        let paired = await NearbyWiFiChannel.hasPairedDevices()
        mark("шаг 4 ок (paired=\(paired))")
        return "publishable=\(pub) subscribable=\(sub) "
             + "pairingSupported=\(supported) paired=\(paired)"
    }
}

/// Половина показывающего карточку: системный экран готовности.
@available(iOS 26.0, *)
struct NearbyPairingHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        guard let service = WAPublishableService
            .allServices[NearbyWiFiChannel.serviceName] else {
            return UIViewController()
        }
        // .permanent — знакомство телефонов остаётся навсегда, экран
        // больше никогда не появится
        return DDDevicePairingViewController(
            listenerProvider: .wifiAware(
                .connecting(to: service, from: .allPairedDevices)),
            access: .permanent)
    }

    func updateUIViewController(_ controller: UIViewController,
                                context: Context) {}
}

/// Половина сканирующего: системный выбор телефона собеседника.
@available(iOS 26.0, *)
struct NearbyPairingPicker: UIViewControllerRepresentable {
    var onFinished: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard let service = WASubscribableService
            .allServices[NearbyWiFiChannel.serviceName],
            let picker = DDDevicePickerViewController(
                browseDescriptor: WASubscriberBrowser
                    .wifiAware(.connecting(to: .allPairedDevices,
                                           from: service))
                    .makeDescriptor(),
                parameters: nil,
                access: .permanent)
        else {
            onFinished()
            return UIViewController()
        }
        // выбор телефона доводится системой; наш код только узнаёт,
        // что всё закончилось, и закрывает лист
        Task { @MainActor in
            _ = try? await picker.endpoint
            onFinished()
        }
        return picker
    }

    func updateUIViewController(_ controller: UIViewController,
                                context: Context) {}
}

/// Подпись человеку над системным экраном — нашими словами.
struct NearbyPairingCaption: View {
    var body: some View {
        Text("Знакомим телефоны, чтобы рядом связь была быстрее. "
           + "Это один раз при знакомстве — больше не спросим.")
            .font(.system(size: 13))
            .foregroundStyle(RMDesign.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
    }
}
