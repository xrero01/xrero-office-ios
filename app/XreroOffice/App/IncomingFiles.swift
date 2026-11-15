import SwiftUI
import UIKit

/// Where an open document's bytes are written (plan S11). Shown to the user so an edit is never made "somewhere".
enum DocumentOrigin {
    /// A file in the app's own folder (On My iPhone > Xrero Office): created here, or reopened from Recent.
    case own
    /// A file opened in place from Files (iCloud Drive, another app's folder): the original is edited.
    case original
    /// A copy the system handed over from Mail / WhatsApp / a share sheet ("Copy to Xrero Office"). It arrives in the
    /// app's Inbox, which the app may read and delete but should not keep editing; it is moved into the app's own
    /// folder under a clean name before the editor opens, so every save lands in a file the user can find in Files.
    case importedCopy
}

/// Files handed to the app by other apps (plan S11).
enum IncomingFiles {
    private static var documents: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    private static func real(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// A copy the system placed in the app's Inbox: Documents/Inbox (Mail, older share sheets) or
    /// tmp/<bundle id>-Inbox (current iOS). Anything else is a file the user picked or opened in place.
    static func isIncomingCopy(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let p = real(url)
        if let docs = documents, p.hasPrefix(real(docs) + "/Inbox/") { return true }
        let tmp = real(FileManager.default.temporaryDirectory)
        if p.hasPrefix(tmp + "/") {
            let rest = p.dropFirst(tmp.count + 1).split(separator: "/")
            if let first = rest.first, rest.count > 1, first == "Inbox" || first.hasSuffix("-Inbox") { return true }
        }
        return false
    }

    /// How a file that is about to be edited relates to what the user sees in Files.
    static func origin(of url: URL) -> DocumentOrigin {
        if let docs = documents, real(url).hasPrefix(real(docs) + "/") { return .own }
        return .original
    }

    /// Moves an Inbox copy into the app's own folder and returns its new place. The name is the attachment's own,
    /// cleaned; a file already there is NEVER replaced ("Report.docx" -> "Report 2.docx"), so an earlier copy the
    /// user edited stays as it was. Throws when the bytes could not be put there: the caller then opens nothing
    /// rather than an editor whose saves would go to the Inbox.
    static func importCopy(_ src: URL) throws -> URL {
        let fm = FileManager.default
        guard let docs = documents else { throw CocoaError(.fileNoSuchFile) }
        let name = cleanName(src.lastPathComponent)
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var dest = docs.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = docs.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : "." + ext))
            n += 1
        }
        let size = (try? fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.intValue
        do {
            try fm.moveItem(at: src, to: dest)
        } catch {
            // the Inbox may be read-only for moves on some systems: copy, check, then tidy the Inbox
            NSLog("XR open-in move failed (%@), copying", error.localizedDescription)
            try fm.copyItem(at: src, to: dest)
            let copied = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue
            guard size == nil || copied == size else {
                try? fm.removeItem(at: dest)
                throw CocoaError(.fileWriteUnknown)
            }
            try? fm.removeItem(at: src)
        }
        NSLog("XR open-in copy %@ -> %@", src.lastPathComponent, dest.lastPathComponent)
        return dest
    }

    /// The attachment's name as a file name in the app's folder: one Unicode form (NFC, so an Arabic name from
    /// another app matches the same name typed here), no path separators, no leading dots, never empty.
    static func cleanName(_ raw: String) -> String {
        var s = raw.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        let ext = (s as NSString).pathExtension
        var base = (s as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = OfficeKind(url: URL(fileURLWithPath: s)).map(L.name) ?? "Document" }
        return base + (ext.isEmpty ? "" : "." + ext)
    }
}

// MARK: the editor's notice

extension View {
    /// The one-time capsule for an imported copy (plan S11): on the first edit it says the edits go to a copy kept in
    /// the app's own folder, and offers Show in Files. Nothing for a file opened in place or the app's own files.
    func importedCopyNotice(_ origin: DocumentOrigin?, fileURL: URL?, state: EditorState, ar: Bool) -> some View {
        overlay(alignment: .top) {
            if origin == .importedCopy { ImportedCopyNotice(state: state, fileURL: fileURL, ar: ar) }
        }
    }
}

/// Observes the editor's state on its own, so the editor screen itself never redraws for it.
struct ImportedCopyNotice: View {
    @ObservedObject var state: EditorState
    let fileURL: URL?
    let ar: Bool
    @State private var phase = 0                       // 0 waiting for the first edit, 1 shown, 2 done (one time)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var headline: String { ar ? "تعديل نسخة محفوظة في Xrero Office" : "Editing a copy saved in Xrero Office" }
    private var place: String {
        ar ? "في تطبيق الملفات: \(pad ? "على iPad" : "على iPhone")، مجلد Xrero Office"
           : "Files: \(pad ? "On My iPad" : "On My iPhone") › Xrero Office"
    }

    var body: some View {
        VStack {
            if phase == 1 { capsule.transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity)) }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4), value: phase)
        .onReceive(state.objectWillChange) { _ in
            // objectWillChange fires before the new value is set: read it on the next turn of the main loop
            DispatchQueue.main.async {
                guard phase == 0, state.modified || state.canUndo || !state.saved else { return }
                show()
            }
        }
    }

    private func show() {
        phase = 1
        NSLog("XR open-in notice shown")
        UIAccessibility.post(notification: .announcement, argument: headline + ". " + place)
        // long enough to read and reach the button; longer when VoiceOver reads it
        let hold: Double = UIAccessibility.isVoiceOverRunning ? 20 : 9
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { if phase == 1 { phase = 2 } }
    }

    private var capsule: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.xrOnTeal)
                .frame(width: 34, height: 34)
                .background(Color.xrTeal, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("xr-copy-notice-text")
                Text(place)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("xr-copy-notice-place")
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: showInFiles) {
                Text(ar ? "عرض في الملفات" : "Show in Files")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.xrOnTeal)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Color.xrTeal, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("xr-copy-show")
            Button { phase = 2 } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ar ? "إغلاق" : "Close")
            .accessibilityIdentifier("xr-copy-close")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.xrTeal.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("xr-copy-notice")
    }

    /// Opens the Files app at the copy's folder (On My iPhone > Xrero Office).
    private func showInFiles() {
        guard let folder = fileURL?.deletingLastPathComponent(),
              let path = folder.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "shareddocuments://" + path) else { return }
        UIApplication.shared.open(url)
    }
}
