import SwiftUI

/// Centralized semantic design tokens mapping to native system colors and materials.
enum AppTheme {
    /// The primary screen/window background.
    static let background = Color.platformGroupedBackground
    /// Background for card-like grouped containers sitting on top of `background`.
    static let card = Color.platformSecondaryGroupedBackground
    /// Background for a further nested surface (like placeholder tiles).
    static let surface = Color.platformTertiaryGroupedBackground
}

extension Color {
    static var platformGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var platformSecondaryGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var platformTertiaryGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .tertiarySystemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}
