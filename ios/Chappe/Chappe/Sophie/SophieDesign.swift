import SwiftUI

// ============================================================================
// Дизайн-токены Софи — из design/sophie/design_tokens.md (тёмная тема,
// единственная по канону дизайна). Только значения: цвета, радиусы,
// отступы. Источник истины — markdown-файл; при изменении токенов
// править оба места.
//
// Правило двух акцентов: синий (#5aaef2 и производные) — ТОЛЬКО Софи;
// нейтральный акцент приложения #9184d9 — всё остальное. Не смешивать.
// ============================================================================

nonisolated enum SophieDesign {

    // Полотно и поверхности
    static let background = Color(hex: 0x161826)      // фон приложения
    static let surface1 = Color(hex: 0x1c1e2c)        // поле ввода, карточки
    static let textPrimary = Color(hex: 0xe9e9ed)
    static let textSecondary = Color(hex: 0xe9e9ed).opacity(0.55)
    static let textTertiary = Color(hex: 0xe9e9ed).opacity(0.40)

    // Синий Софи (только агент)
    static let sophie = Color(hex: 0x5aaef2)            // обводки, точки «думает»
    static let sophieLight = Color(hex: 0x8ccbff)       // глиф, иконки
    static let sophieSurface = Color(hex: 0x1b3b58)     // свой пузырь в чате Софи
    static let sophieBubbleIn = Color(hex: 0x1a2836)    // пузырь Софи
    static let sophieText = Color(hex: 0xdbeaf8)        // текст на синих поверхностях
    static let sophieTextStrong = Color(hex: 0xeaf3fb)  // текст своего пузыря

    // Служебный
    static let danger = Color(hex: 0xe2564f)

    // Радиусы пузырей: свой 16/16/4/16, чужой (Софи) 16/16/16/4
    static let bubbleRadius: CGFloat = 16
    static let bubbleTightCorner: CGFloat = 4

    // Отступы (шкала токенов)
    static let screenPadding: CGFloat = 14        // горизонтальные поля экрана
    static let messageSpacing: CGFloat = 12       // промежуток между сообщениями
    static let bubblePaddingH: CGFloat = 13       // внутри пузыря 10/13
    static let bubblePaddingV: CGFloat = 10
    static let fieldRadius: CGFloat = 22          // поле ввода — капсула, высота 44
    static let controlSize: CGFloat = 44          // мин. интерактивный элемент

    // Типографика (размеры из токенов; гарнитура — системная,
    // Inter в бандл не тащим на этой фазе)
    static let messageFont = Font.system(size: 15)          // текст сообщения 15/1.45
    static let captionFont = Font.system(size: 12.5)        // подпись/описание
}

/// Пузырь с асимметричным углом: 16/16/4/16 (свой) или 16/16/16/4 (Софи).
nonisolated struct BubbleShape: Shape {
    let ownSide: Bool     // true = свой (острый угол справа-внизу)

    func path(in rect: CGRect) -> Path {
        let r = SophieDesign.bubbleRadius
        let t = SophieDesign.bubbleTightCorner
        return Path(roundedRect: rect,
                    cornerRadii: RectangleCornerRadii(
                        topLeading: r,
                        bottomLeading: ownSide ? r : t,
                        bottomTrailing: ownSide ? t : r,
                        topTrailing: r))
    }
}

extension Color {
    /// Цвет из hex-значения токена (0xRRGGBB).
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
