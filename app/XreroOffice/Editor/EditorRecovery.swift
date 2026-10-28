import SwiftUI
import UIKit

/// What the editor screen shows after iOS ended the editor's web process (see EditorWebView.recoverFromTermination):
/// a short capsule once the last saved version is back on screen, or - when the document keeps taking the process
/// down - a page that offers Share and Back instead of a blank editor. Used by EditorScreen and the CI AutotestScreen.
struct RecoveryNotice: Equatable {
    let id = UUID()
    /// the engine had marked the document edited: changes since the last save may be missing
    let edited: Bool
}

extension View {
    func editorRecovery(notice: Binding<RecoveryNotice?>, tooLarge: Bool, ar: Bool,
                        share: @escaping () -> Void, back: @escaping () -> Void) -> some View {
        modifier(EditorRecoveryOverlay(notice: notice, tooLarge: tooLarge, ar: ar, share: share, back: back))
    }
}

struct EditorRecoveryOverlay: ViewModifier {
    @Binding var notice: RecoveryNotice?
    var tooLarge: Bool
    var ar: Bool
    var share: () -> Void
    var back: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if tooLarge { EditorTooLargeView(ar: ar, share: share, back: back) }
            }
            .overlay(alignment: .top) {
                if let n = notice, !tooLarge {
                    RecoveredCapsule(edited: n.edited, ar: ar)
                        .padding(.top, 8)                 // just under the navigation bar
                        .padding(.horizontal, 16)
                        .transition(.opacity)             // a fade: fine with Reduce Motion
                }
            }
            .animation(.easeInOut(duration: 0.2), value: notice)
            .task(id: notice?.id) {                       // shown for 3 s; a newer notice restarts the time
                guard notice != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { notice = nil }
            }
            .onChange(of: notice) { _, n in               // VoiceOver: 3 s is too short to find it by swiping
                if let n { UIAccessibility.post(notification: .announcement, argument: RecoveredCapsule.text(edited: n.edited, ar: ar)) }
            }
            .onChange(of: tooLarge) { _, shown in
                if shown { UIAccessibility.post(notification: .screenChanged, argument: nil) }
            }
    }
}

/// "Recovered your document." (+ "Changes since the last save may be missing." when it had been edited).
struct RecoveredCapsule: View {
    let edited: Bool
    let ar: Bool

    static func text(edited: Bool, ar: Bool) -> String {
        let back = ar ? "تم استرداد مستندك." : "Recovered your document."
        guard edited else { return back }
        return back + " " + (ar ? "قد تكون التعديلات بعد آخر حفظ مفقودة." : "Changes since the last save may be missing.")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(Self.text(edited: edited, ar: ar))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)   // two lines on a phone rather than truncated
                .accessibilityIdentifier("xr-recovered")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .frame(maxWidth: 560)
        // system material: turns solid by itself with Reduce Transparency; the hairline keeps it apart from the page
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        .allowsHitTesting(false)                                // never in the way of a tap on the page below
    }
}

/// The document ended the editor's web process twice within a minute: say so plainly and offer the two ways out.
struct EditorTooLargeView: View {
    let ar: Bool
    var share: () -> Void
    var back: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(ar ? "هذا الملف كبير جدًا لتحريره على هذا الجهاز" : "This file is too large to edit on this device",
                  systemImage: "exclamationmark.triangle")
        } description: {
            Text(ar ? "آخر نسخة محفوظة لم تتغيّر. يمكنك مشاركتها أو العودة إلى المستندات."
                    : "Your last saved version is unchanged. You can share it or go back to your documents.")
        } actions: {
            Button(action: share) {
                Label(ar ? "مشاركة" : "Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("xr-recovery-share")
            Button(action: back) {
                Text(ar ? "العودة إلى المستندات" : "Back to Documents")
            }
            .controlSize(.large)
            .accessibilityIdentifier("xr-recovery-back")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
    }
}
