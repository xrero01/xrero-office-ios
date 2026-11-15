import UIKit

/// Plan C1: the paragraph direction follows the keyboard. When the user switches the keyboard (the globe key) while
/// the caret sits in an EMPTY paragraph of a Word document, that paragraph turns right-to-left for an Arabic (or other
/// right-to-left) keyboard and left-to-right for a Latin one. A paragraph that has text is never changed.
///
/// One bridge call per switch (UITextInputMode.currentInputModeDidChangeNotification, see EditorWebView.Coordinator
/// .keyboardLanguageChanged): never on the keystroke path, never while a word is being composed (marked text), and the
/// engine side (__xrKbDirection in web/xr-host.js) checks again that the paragraph is empty and nothing is selected.
///
/// Flag: UserDefaults "xr.kbDirection" ("Match paragraph direction to keyboard" / «مطابقة اتجاه الفقرة مع لوحة
/// المفاتيح»). Unset = on when the app is in Arabic, off in English (plan C1 design); an explicit YES / NO (also
/// the launch-argument form "-xr.kbDirection YES" the CI gate uses) wins.
enum KeyboardDirection {
    static let flagKey = "xr.kbDirection"

    static func enabled(lang: String) -> Bool {
        if UserDefaults.standard.object(forKey: flagKey) != nil { return UserDefaults.standard.bool(forKey: flagKey) }
        return lang == "ar"
    }

    /// true = right-to-left keyboard, false = left-to-right, nil = no text language (emoji, dictation, unknown):
    /// those switches change nothing. `primaryLanguage` is a BCP 47 tag such as "ar", "en-US", "he-IL".
    static func rightToLeft(_ primaryLanguage: String?) -> Bool? {
        guard let tag = primaryLanguage?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else { return nil }
        let base = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        if base.isEmpty || ["emoji", "dictation", "mul", "und", "zxx"].contains(base) { return nil }
        switch NSLocale.characterDirection(forLanguage: base) {
        case .rightToLeft: return true
        case .leftToRight: return false
        default: return nil                                     // top-to-bottom / unknown: leave the paragraph alone
        }
    }
}
