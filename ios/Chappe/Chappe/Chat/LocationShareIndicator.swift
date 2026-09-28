import SwiftUI
import Combine

// ============================================================================
// Индикатор геотрансляции в чате (блок 5, спека владельца 10.08):
// пока грант этому контакту жив, собеседникова сторона чата показывает
// «Делитесь локацией · осталось N» и даёт прекратить досрочно.
//
// Право на раскрытие целиком в политике WP4 (Geo/Privacy) — здесь
// только чтение activeGrant и вызов revoke; отзыв мгновенный и
// односторонний, следующий маячок не уходит. Истечение TTL гасит
// индикатор само (минутный тик перечитывает грант).
// ============================================================================

struct LocationShareIndicator: View {

    let contactID: String

    @State private var grant: ShareGrant?
    private let tick = Timer.publish(every: 30, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Group {
            if let grant {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(RMDesign.accentLight)
                    Text("Делитесь локацией · осталось "
                         + Self.remainingText(grant.remainingSeconds(
                            now: Date())))
                        .font(.system(size: 12.5))
                        .foregroundStyle(RMDesign.textSecondary)
                    Spacer(minLength: 8)
                    Button("Прекратить") {
                        LocationDisclosurePolicy.revoke(contactID: contactID)
                        self.grant = nil
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(RMDesign.warning)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RMDesign.surface1)
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        grant = LocationDisclosurePolicy.activeGrant(for: contactID,
                                                     now: Date())
    }

    /// «3 ч 12 мин» / «45 мин» / «меньше минуты» — человеку, не логу.
    static func remainingText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "меньше минуты" }
        if minutes < 60 { return "\(minutes) мин" }
        return "\(minutes / 60) ч \(minutes % 60) мин"
    }
}
