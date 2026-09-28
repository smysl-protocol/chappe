import SwiftUI

// ============================================================================
// Предложение познакомить телефоны для контактов, добавленных НЕ при
// встрече (дополнение к фазе 1, 07.08).
//
// Показывается только в открытом чате и только когда собеседник рядом
// (пакет от него пришёл прямым путём). Отказ запоминается навсегда;
// ручная дверь обратно — кнопка в карточке контакта.
//
// Формулировки — про пользу человеку, а не про технологию: «Познакомить
// телефоны, чтобы рядом связь была быстрее». Слов «Wi-Fi», «спаривание»,
// «пиры» в интерфейсе нет.
//
// Двусторонность (п.3 брифа): системный запрос придёт и второму. Если он
// не в приложении, знакомство не состоится — и человек обязан увидеть
// честное «не получилось», а не молчание. Исход проверяется по факту:
// появилось ли знакомство в системе (см. checkOutcome).
// ============================================================================

/// Полоска-предложение над полем ввода в чате.
struct NearbyPairingOfferBar: View {
    let contactName: String
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal")
                .foregroundStyle(RMDesign.accentLight)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(contactName) рядом")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RMDesign.textPrimary)
                Text("Познакомить телефоны, чтобы рядом связь была быстрее")
                    .font(.system(size: 12))
                    .foregroundStyle(RMDesign.textSecondary)
            }
            Spacer(minLength: 6)
            Button("Не нужно", action: onDecline)
                .font(.system(size: 12))
                .foregroundStyle(RMDesign.textTertiary)
            Button("Познакомить", action: onAccept)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(RMDesign.accentLight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RMDesign.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
    }
}

/// Исход попытки: проверяется фактом, а не молчанием.
enum NearbyPairingOutcome {
    /// Сколько ждём появления знакомства после закрытия системного экрана.
    static let settleSeconds: Double = 1.5

    /// Итоговая строка человеку: nil — получилось, иначе честная причина.
    static func failureLine(pairedAfter: Bool) -> String? {
        pairedAfter ? nil
            : "Не получилось: собеседнику тоже нужно открыть приложение, "
            + "когда вы рядом. Попробуйте ещё раз — кнопка есть в карточке "
            + "контакта."
    }

    /// Появилось ли знакомство телефонов после системного экрана.
    static func settled() async -> Bool {
        try? await Task.sleep(for: .seconds(settleSeconds))
        guard #available(iOS 26.0, *) else { return false }
        return await NearbyWiFiChannel.hasPairedDevices()
    }
}
