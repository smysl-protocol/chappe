import SwiftUI

// ============================================================================
// Баннер знакомства (решение владельца 08.08): «Рядом кто-то с именем
// "X"». Логика и границы — в IntroduceCenter (Transport/NearbyIntroduce);
// здесь только вид. Имя подано как ЗАЯВЛЕННОЕ удалённой стороной —
// формулировка обязана это отражать (условие владельца).
// ============================================================================

/// Оверлей поверх корневого таббара: баннер + честная строка гейта.
struct IntroduceBannerOverlay: View {
    @ObservedObject private var center = IntroduceCenter.shared
    @State private var confirming: IntroduceCenter.Offer?

    var body: some View {
        VStack(spacing: 8) {
            if let offer = center.offer {
                banner(offer)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let notice = center.notice {
                noticeCard(notice)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .animation(.snappy(duration: 0.25), value: center.offer)
        .animation(.snappy(duration: 0.25), value: center.notice)
        .sheet(item: $confirming) { offer in
            IntroduceConfirmSheet(
                offer: offer,
                onConfirm: {
                    confirming = nil
                    center.accept()
                },
                onCancel: { confirming = nil })
            .presentationDetents([.medium])
        }
    }

    private func banner(_ offer: IntroduceCenter.Offer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(RMDesign.accentLight)
            VStack(alignment: .leading, spacing: 2) {
                Text("Рядом кто-то с именем «\(offer.contact.name)»")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(RMDesign.textPrimary)
                Text("Предлагает познакомиться. Имя — то, что человек "
                   + "сам о себе заявил.")
                    .font(.system(size: 12))
                    .foregroundStyle(RMDesign.textSecondary)
            }
            Spacer(minLength: 6)
            Button("Не нужно") { center.decline() }
                .font(.system(size: 12))
                .foregroundStyle(RMDesign.textTertiary)
            Button("Познакомиться") { confirming = offer }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(RMDesign.accentLight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RMDesign.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    private func noticeCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(RMDesign.warning)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(RMDesign.textSecondary)
            Spacer(minLength: 4)
            Button {
                center.notice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RMDesign.textTertiary)
            }
        }
        .padding(10)
        .background(RMDesign.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

extension IntroduceCenter.Offer: Identifiable {
    var id: String { contact.id }
}

/// Подтверждение знакомства: отпечаток, честность про «непроверен» и —
/// для объявления — про ответную карточку в эфир.
struct IntroduceConfirmSheet: View {
    let offer: IntroduceCenter.Offer
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Познакомиться?")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(RMDesign.textPrimary)
            LabeledContent("Заявленное имя", value: offer.contact.name)
            LabeledContent("Отпечаток") {
                Text(offer.contact.id)
                    .font(.system(.body, design: .monospaced))
            }
            Label {
                Text("Карточка пришла по воздуху без визуальной сверки — "
                   + "её мог отправить кто угодно в радиусе. Контакт будет "
                   + "помечен «непроверен»; сверьте отпечаток голосом или "
                   + "лично, когда удобно — отметка ставится только после "
                   + "сверки.")
            } icon: {
                Image(systemName: "exclamationmark.shield")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(RMDesign.warning)
            if !offer.isReply {
                Text("В ответ ваша карточка — имя и ключ — уйдёт по "
                   + "воздуху и будет видна телефонам рядом в этот момент.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RMDesign.textSecondary)
            }
            HStack(spacing: 10) {
                Button {
                    onConfirm()
                } label: {
                    Text("Познакомиться")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(RMDesign.accentLight)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RMDesign.accentSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button {
                    onCancel()
                } label: {
                    Text("Отмена")
                        .font(.system(size: 14.5))
                        .foregroundStyle(RMDesign.textSecondary)
                        .frame(minWidth: 90, minHeight: 48)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(RMDesign.background)
        .preferredColorScheme(.dark)
    }
}
