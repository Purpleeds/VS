#if canImport(SwiftUI)
import SwiftUI

/// Colours are defined in code (no asset catalog).
enum Theme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let surface = Color(red: 0.10, green: 0.12, blue: 0.19)
    static let surfaceHighlight = Color(red: 0.16, green: 0.19, blue: 0.29)
    static let accent = Color(red: 0.20, green: 0.85, blue: 0.75)
    static let accentSecondary = Color(red: 1.00, green: 0.45, blue: 0.55)
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.62, green: 0.66, blue: 0.78)
}
#endif
