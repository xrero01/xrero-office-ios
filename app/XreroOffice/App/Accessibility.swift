import SwiftUI
import UIKit

/// Accessibility fallbacks (plan S12): the words VoiceOver reads for native controls, and the honest note about the
/// document page.
///
/// The document page is drawn by the editor engine on a canvas: VoiceOver can read the app's own bars, menus and
/// sheets (native SwiftUI) and the editor's ribbon buttons, but NOT the text on the page itself. The app says so
/// instead of pretending otherwise: with VoiceOver on, a note under the top bar states the limit and the way around
/// it (Share the file to an app that reads it aloud). The App Store accessibility labels must not claim VoiceOver
/// support for documents either.
enum A11yText {
    static func canvasNote(_ ar: Bool) -> String {
        ar ? "لا يستطيع VoiceOver قراءة صفحة المستند نفسها. الأشرطة والقوائم وورقة التنسيق مقروءة. لسماع النص، شارك الملف (⋯ > مشاركة) مع تطبيق يقرأ بصوت عالٍ."
           : "VoiceOver can't read the document page itself. The bars, menus and Format sheet are read. To hear the text, share the file (⋯ > Share) to an app that reads aloud."
    }
    static func close(_ ar: Bool) -> String { ar ? "إغلاق الملاحظة" : "Close note" }
    // hints: what a control does, when the label alone does not say it
    static func backHint(_ ar: Bool) -> String { ar ? "يحفظ المستند ويعود إلى قائمة المستندات" : "Saves the document and goes back to your documents" }
    static func undoHint(_ ar: Bool) -> String { ar ? "يتراجع عن آخر تعديل" : "Undoes the last change" }
    static func redoHint(_ ar: Bool) -> String { ar ? "يعيد آخر تعديل تم التراجع عنه" : "Redoes the last undone change" }
    static func moreHint(_ ar: Bool) -> String { ar ? "بحث وحفظ ومشاركة وتصدير والمزيد" : "Find, save, share, export and more" }
    static func formatHint(_ ar: Bool) -> String { ar ? "يفتح الخط والحجم والنمط والفقرة والإدراج" : "Opens font, size, style, paragraph and insert" }
    static func newHint(_ ar: Bool) -> String { ar ? "ينشئ ملفًا فارغًا جديدًا ويفتحه" : "Creates a new blank file and opens it" }
    static func browseHint(_ ar: Bool) -> String { ar ? "يفتح قائمة الملفات لاختيار ملف" : "Opens the file browser to pick a file" }
    static func recentHint(_ ar: Bool) -> String { ar ? "يفتح الملف" : "Opens the file" }
    static func homeMoreHint(_ ar: Bool) -> String { ar ? "الحساب واللغة وحول التطبيق والخصوصية والملاحظات" : "Account, language, about, privacy and feedback" }
    static func hideKeyboardHint(_ ar: Bool) -> String { ar ? "يخفي لوحة المفاتيح" : "Hides the keyboard" }
}

/// The note under the editor's top bar while VoiceOver is on (or `-xr.canvasNote YES`, for the UI test: the simulator
/// cannot turn VoiceOver on). Closable with a 44 pt button; closed stays closed for this editor.
struct CanvasAccessibilityNote: ViewModifier {
    var ar: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var closed = false

    private var shown: Bool { !closed && (voiceOver || UserDefaults.standard.bool(forKey: "xr.canvasNote")) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if shown {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.tint)
                            .padding(.top, 12)
                            .accessibilityHidden(true)
                        Text(A11yText.canvasNote(ar))
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("xr-a11y-canvas-note")
                        Button { closed = true } label: {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(A11yText.close(ar))
                        .accessibilityIdentifier("xr-a11y-canvas-close")
                    }
                    .padding(.leading, 14)
                    .frame(maxWidth: 560)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(contrast == .increased ? Color.primary.opacity(0.6) : Color(.separator),
                                      lineWidth: contrast == .increased ? 1 : 0.5))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
                    .accessibilityElement(children: .contain)
                    .onAppear {
                        if voiceOver { UIAccessibility.post(notification: .announcement, argument: A11yText.canvasNote(ar)) }
                    }
                }
            }
    }
}

extension View {
    /// The honest VoiceOver note over the drawn document page (plan S12).
    func canvasAccessibilityNote(ar: Bool) -> some View { modifier(CanvasAccessibilityNote(ar: ar)) }

    /// An animation that is dropped with Reduce Motion.
    func xrAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(XRMotion(animation: animation, value: value))
    }
}

private struct XRMotion<V: Equatable>: ViewModifier {
    var animation: Animation
    var value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : animation, value: value) }
}
