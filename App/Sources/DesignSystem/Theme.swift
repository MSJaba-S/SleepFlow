import SwiftUI
import UIKit
import SleepCore

/// SleepFlow's visual language: deep midnight blues, navy surfaces and warm orange/amber accents.
/// Dark is the primary appearance; every colour has a light-mode counterpart.
enum Theme {
    // MARK: Colours

    static let background = dynamic(light: 0xF3F5FB, dark: 0x060A18)
    static let backgroundTop = dynamic(light: 0xE6EBF8, dark: 0x0E1636)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x101932)
    static let surfaceRaised = dynamic(light: 0xF6F7FC, dark: 0x18234A)
    static let stroke = dynamic(light: 0x0B1226, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.07)
    static let textPrimary = dynamic(light: 0x0B1226, dark: 0xF3F5FF)
    static let textSecondary = dynamic(light: 0x4A5372, dark: 0xA9B2CF)
    static let textTertiary = dynamic(light: 0x7B839E, dark: 0x6D7695)

    static let accent = Color(hex: 0xFF8A3D)
    static let accentSoft = Color(hex: 0xFFB25B)
    static let accentText = Color(hex: 0x1A0F05)
    static let positive = Color(hex: 0x37D39B)
    static let negative = Color(hex: 0xFF6B6B)
    static let info = Color(hex: 0x7FA2FF)

    static let stageAwake = Color(hex: 0xFF9A62)
    static let stageLight = Color(hex: 0x7FA2FF)
    static let stageDeep = Color(hex: 0x5146D8)

    static func color(for stage: SleepStage) -> Color {
        switch stage {
        case .awake: return stageAwake
        case .light: return stageLight
        case .deep: return stageDeep
        }
    }

    static func color(for score: Int) -> Color {
        switch score {
        case 80...: return positive
        case 60..<80: return accentSoft
        default: return negative
        }
    }

    /// Ring gradient: warm orange to amber.
    static var scoreGradient: AngularGradient {
        AngularGradient(
            colors: [accent, accentSoft, accent],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    // MARK: Layout

    static let cornerRadius: CGFloat = 22
    static let smallCornerRadius: CGFloat = 14
    static let padding: CGFloat = 20
    static let spacing: CGFloat = 14

    // MARK: Helpers

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

extension Font {
    /// Rounded display numerals for scores and durations.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

extension AppSettings.Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}
