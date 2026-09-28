import SwiftUI
import Combine

// ============================================================================
// Меню шеринга позиции в чате контакта (WP4-UI + п.3/п.4 плана 29.07).
//
// UI — только обёртка над LocationDisclosurePolicy: выдать грант с TTL
// и точностью, отозвать, показать индикатор, пока активен. Сама
// гарантия невозможности утечки — в политике, не здесь.
//
// Фоновые обновления (CLBackgroundActivitySession) живут ровно от
// выдачи гранта до его конца и НЕ переживают перезапуск приложения —
// состояние «грант активен, обновления не идут» показывается явно.
// ============================================================================

struct LocationShareMenu: View {

    let contactID: String

    /// Тик раз в минуту — индикатор и остаток TTL живут во времени.
    @State private var now = Date()
    @ObservedObject private var session = ShareSessionController.shared
    private let timer = Timer.publish(every: 60, on: .main, in: .common)
        .autoconnect()

    private var activeGrant: ShareGrant? {
        LocationDisclosurePolicy.activeGrant(for: contactID, now: now)
    }

    var body: some View {
        Menu {
            if let grant = activeGrant {
                Section(remainingText(grant)) {
                    // Явное состояние фона (п.2, 29.07): возобновлены при
                    // открытии / идут / не идут — без догадок
                    if session.backgroundUpdatesActive {
                        Text(session.resumedAutomatically
                             ? "Грант активен, обновления возобновлены"
                             : "Обновления в фоне идут")
                    } else {
                        Text("Обновления в фоне не идут — начните делиться заново")
                    }
                    Button(role: .destructive) {
                        LocationDisclosurePolicy.revoke(contactID: contactID)
                        session.syncWithGrants()
                        now = Date()   // мгновенный отзыв — мгновенный UI
                    } label: {
                        Label("Перестать делиться", systemImage: "location.slash")
                    }
                }
            } else {
                // Копирайт по решению разработчика (п.4): что именно видит
                // собеседник во время шеринга и после него
                Section("Пока делитесь — собеседник видит вашу позицию; после окончания — только последнюю известную") {
                    Button("Точно, 4 часа") {
                        grant(.exact, hours: 4)
                    }
                    Button("Грубо (~1 км), 4 часа") {
                        grant(.coarse(geohashLength: 6), hours: 4)
                    }
                    Button("Грубо (~5 км), сутки") {
                        grant(.coarse(geohashLength: 5), hours: 24)
                    }
                }
            }
        } label: {
            // Индикатор: заметно, пока грант активен; предупреждающий
            // вид, если грант жив, а фоновые обновления — нет.
            // UX-проход 06.08: в покое НЕ location.slash — перечёркнутая
            // иконка читалась «локация сломана», а это кнопка «поделиться
            // местом»; покой — нейтральный контур
            Image(systemName: activeGrant == nil ? "location"
                  : session.backgroundUpdatesActive ? "location.fill"
                  : "location.fill.viewfinder")
                .foregroundStyle(activeGrant == nil ? RMDesign.textSecondary
                                 : RMDesign.warning)
        }
        .accessibilityLabel(activeGrant == nil ? "Поделиться позицией"
                            : "Позиция передаётся — управлять")
        .onReceive(timer) { now = $0 }
    }

    private func grant(_ precision: PositionPrecision, hours: Double) {
        LocationDisclosurePolicy.grant(to: contactID, precision: precision,
                                       ttlSeconds: hours * 3600, now: Date())
        // Единственное место, включающее фоновые обновления, — выдача
        // гранта; гаснут по отзыву/истечению, перезапуск не восстанавливает
        session.grantIssued()
        now = Date()
        // событие для первого маячка — сам грант (если есть фикс)
        PositionBeacon.shared.afterMessageSent(to: contactID)
    }

    private func remainingText(_ grant: ShareGrant) -> String {
        let left = grant.remainingSeconds(now: now)
        let precisionText: String
        switch grant.precision {
        case .exact: precisionText = "точно"
        case .coarse(let n): precisionText = n >= 6 ? "~1 км" : "грубо"
        }
        return left > 3600
            ? String(format: "Делюсь (%@) ещё %.1f ч", precisionText, left / 3600)
            : String(format: "Делюсь (%@) ещё %.0f мин", precisionText, left / 60)
    }
}
