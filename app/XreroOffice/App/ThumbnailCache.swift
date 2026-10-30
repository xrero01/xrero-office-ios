import SwiftUI
import UIKit
import CryptoKit
import QuickLookThumbnailing

/// First-page pictures of recent files for Home (QuickLook, the same thumbnails the Files app shows), made off the
/// main thread and kept in memory and in Caches/xr-thumbs. The key is the file's path plus its modification date, so a
/// document edited since gets a new picture while an unchanged one is never rendered twice.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, UIImage>()
    private let folder: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("xr-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        memory.countLimit = 60
    }

    /// nil when QuickLook has no real thumbnail for the file (the row then keeps its kind glyph).
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        // files from iCloud Drive / other apps are security-scoped: hold access for the whole generation, then give
        // it back (every start is paired with a stop)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = Self.key(url.path, modified?.timeIntervalSince1970 ?? 0, size)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let file = folder.appendingPathComponent(key + ".png")
        if let d = try? Data(contentsOf: file), let img = UIImage(data: d, scale: scale) {
            memory.setObject(img, forKey: key as NSString)
            return img
        }
        // .thumbnail only: the generic system icon (.icon) would look worse than the row's own kind glyph
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let img = rep.uiImage
        memory.setObject(img, forKey: key as NSString)
        if let png = img.pngData() { try? png.write(to: file, options: .atomic) }
        return img
    }

    /// Stable across launches (String.hashValue is not), and no file name ends up in the cache folder.
    private static func key(_ path: String, _ modified: TimeInterval, _ size: CGSize) -> String {
        let raw = "\(path)|\(modified)|\(Int(size.width))x\(Int(size.height))"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A recent file's picture: the kind glyph at once, replaced by the QuickLook thumbnail when it is ready.
struct RecentThumbnail: View {
    let item: RecentFiles.Item
    var width: CGFloat = 44
    var height: CGFloat = 58
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        let t = HomeTile.of(item.kind)
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.tertiarySystemGroupedBackground)
                Image(systemName: t.symbol)
                    .font(.system(size: width * 0.45, weight: .semibold))
                    .foregroundStyle(t.color)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: item) {
            guard let url = RecentFiles.shared.resolve(item) else { return }
            image = await ThumbnailCache.shared.thumbnail(for: url, size: CGSize(width: width, height: height), scale: scale)
        }
    }
}
