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
    static let grid = Color(red: 0.62, green: 0.66, blue: 0.78)
    /// In tune / good signal.
    static let good = Color(red: 0.30, green: 0.88, blue: 0.48)
    /// Close.
    static let warn = Color(red: 1.00, green: 0.78, blue: 0.28)
    /// Off.
    static let bad = Color(red: 1.00, green: 0.38, blue: 0.38)
    static let gold = Color(red: 1.00, green: 0.82, blue: 0.30)
    static let lane = Color(red: 0.06, green: 0.07, blue: 0.12)
}
#endif
