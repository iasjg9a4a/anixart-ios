import SwiftUI

/// Единая палитра клиента. Тёмная тема — как в оригинальном Anixart.
enum Theme {
    static let accent = Color(hex: 0xFA5C33)
    static let accentSoft = Color(hex: 0xFA5C33).opacity(0.16)

    static let background = Color(hex: 0x0E0F13)
    static let surface = Color(hex: 0x171920)
    static let surfaceHigh = Color(hex: 0x22252F)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)
    static let separator = Color.white.opacity(0.08)

    static let radius: CGFloat = 14
    static let cardRadius: CGFloat = 12
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

extension View {
    /// Карточка на тёмном фоне.
    func cardSurface(cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}
