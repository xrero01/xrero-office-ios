import SwiftUI
import UIKit

/// Xrero's colours, defined once in Assets.xcassets (light + dark there, next to the launch screen's colour) instead of
/// Color(red:...) values scattered through the views. AccentColor is also the app-wide tint (project.yml
/// ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME), so system controls are Xrero teal rather than system blue.
extension Color {
    /// Xrero teal: #1F7A8C, #5CB8C9 in dark mode.
    static let xrTeal = Color("AccentColor")
    /// Text on a filled teal button. White on the dark-mode teal is only 2.3:1, so it turns black there (9:1);
    /// on the light-mode teal white is 5:1.
    static let xrOnTeal = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })

    /// One colour per kind of file. Xrero's own values, not the Office ones; the same in dark mode because the home
    /// tiles put a white symbol on them.
    static let xrDocument = Color("KindDocument")
    static let xrSpreadsheet = Color("KindSpreadsheet")
    static let xrPresentation = Color("KindPresentation")
    static let xrPDF = Color("KindPDF")
}

extension UIColor {
    /// Xrero teal for UIKit controllers (the system document browser).
    static let xrTeal = UIColor(named: "AccentColor") ?? UIColor(red: 0.122, green: 0.478, blue: 0.549, alpha: 1)
}
