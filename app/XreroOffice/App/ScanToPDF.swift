import SwiftUI
import UIKit
import AVFoundation
import VisionKit

/// Scan to PDF (plan S10): the system document camera (VisionKit: edge detection, perspective correction, several
/// pages), saved as one PDF in the app's own folder ("On My iPhone > Xrero Office") and opened at once.
/// Named "Scan 2026-11-15" / "مسح 2026-11-15" (the date in Latin digits, as file names are elsewhere).
/// No camera (the simulator, a Mac) or no camera permission: an honest alert saying so - never a dead button.
final class DocumentScanner: NSObject, VNDocumentCameraViewControllerDelegate {
    static let shared = DocumentScanner()

    private weak var opener: DocumentOpener?

    /// From Home's "Scan to PDF" row and the Scan quick action.
    func start(opener: DocumentOpener, attempt: Int = 0) {
        guard let presenter = Self.topController() else {
            // a cold launch from the quick action: the window may not be up yet
            if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.start(opener: opener, attempt: attempt + 1) }
            } else { NSLog("XR scan: no window to present from") }
            return
        }
        self.opener = opener
        #if XR_AUTOTEST
        // CI only (XR_SCAN_SAMPLE=1): two drawn pages through the same save-and-open path a real scan takes
        if ProcessInfo.processInfo.environment["XR_SCAN_SAMPLE"] == "1" {
            finish(images: Self.samplePages())
            return
        }
        #endif
        guard VNDocumentCameraViewController.isSupported else {
            NSLog("XR scan unavailable: no document camera on this device")
            Self.alert(on: presenter, id: "xr-scan-unavailable", title: ScanText.unavailableTitle,
                       message: ScanText.unavailableMessage, settings: false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            NSLog("XR scan: camera access is off")
            Self.alert(on: presenter, id: "xr-scan-denied", title: ScanText.deniedTitle,
                       message: ScanText.deniedMessage, settings: true)
            return
        default:
            break                                  // not asked yet: the document camera asks (NSCameraUsageDescription)
        }
        let camera = VNDocumentCameraViewController()
        camera.delegate = self
        camera.view.tintColor = .xrTeal
        presenter.present(camera, animated: true)
    }

    // MARK: document camera

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        var images: [UIImage] = []
        for i in 0..<scan.pageCount { images.append(scan.imageOfPage(at: i)) }
        controller.dismiss(animated: true) { self.finish(images: images) }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        NSLog("XR scan failed: %@", error.localizedDescription)
        controller.dismiss(animated: true) {
            guard let top = Self.topController() else { return }
            Self.alert(on: top, id: "xr-scan-failed", title: ScanText.failedTitle, message: error.localizedDescription,
                       settings: false)
        }
    }

    // MARK: saving

    private func finish(images: [UIImage]) {
        guard !images.isEmpty else { return }
        let ar = L.ar
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.writePDF(images, ar: ar) }
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    NSLog("XR scan saved %@ pages=%ld", url.lastPathComponent, images.count)
                    self.opener?.open(url)
                case .failure(let error):
                    NSLog("XR scan save failed: %@", error.localizedDescription)
                    if let top = Self.topController() {
                        Self.alert(on: top, id: "xr-scan-failed", title: ScanText.failedTitle,
                                   message: error.localizedDescription, settings: false)
                    }
                }
            }
        }
    }

    /// One page per scanned image, A4 width (595 pt) with the image's own proportions, JPEG-compressed so a few
    /// pages stay a few hundred kB to a few MB.
    static func writePDF(_ images: [UIImage], ar: Bool) throws -> URL {
        let fm = FileManager.default
        let folder = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let base = (ar ? "مسح " : "Scan ") + day.string(from: Date())
        var url = folder.appendingPathComponent(base + ".pdf")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).pdf")
            n += 1
        }
        let width: CGFloat = 595
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: base, kCGPDFContextCreator as String: "Xrero Office"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 842), format: format)
        let data = renderer.pdfData { ctx in
            for image in images {
                autoreleasepool {
                    let size = image.size
                    let height = size.width > 0 ? (width * size.height / size.width).rounded() : 842
                    let page = CGRect(x: 0, y: 0, width: width, height: height)
                    ctx.beginPage(withBounds: page, pageInfo: [:])
                    let jpeg = image.jpegData(compressionQuality: 0.75).flatMap { UIImage(data: $0) } ?? image
                    jpeg.draw(in: page)
                }
            }
        }
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        return url
    }

    #if XR_AUTOTEST
    /// two plain "paper" pages with a few lines of text, as a camera would hand them over
    private static func samplePages() -> [UIImage] {
        (1...2).map { n in
            let size = CGSize(width: 1240, height: 1754)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor(white: 0.97, alpha: 1).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                let text = "Xrero scan sample - page \(n)\nفاتورة رقم \(n)" as NSString
                text.draw(at: CGPoint(x: 120, y: 160),
                          withAttributes: [.font: UIFont.systemFont(ofSize: 56), .foregroundColor: UIColor.darkGray])
            }
        }
    }
    #endif

    // MARK: presenting

    /// The front-most controller of the foreground window (the scan can be started before Home's views are wired).
    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        let windows = scenes.flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return nil }
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        return top
    }

    private static func alert(on vc: UIViewController, id: String, title: String, message: String, settings: Bool) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.view.accessibilityIdentifier = id
        if settings {
            a.addAction(UIAlertAction(title: L.cancel, style: .cancel))
            a.addAction(UIAlertAction(title: ScanText.openSettings, style: .default) { _ in
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            })
        } else {
            a.addAction(UIAlertAction(title: L.ok, style: .default))
        }
        vc.present(a, animated: true)
    }
}

/// Scan words in the interface language (EN/AR).
enum ScanText {
    static var ar: Bool { L.ar }
    static var rowTitle: String { ar ? "مسح إلى PDF" : "Scan to PDF" }
    static var rowDetail: String { ar ? "صوّر الورق بالكاميرا واحفظه ملف PDF" : "Use the camera to turn paper into a PDF" }
    static var unavailableTitle: String { ar ? "المسح غير متاح" : "Scanning isn't available" }
    static var unavailableMessage: String {
        ar ? "لا توجد في هذا الجهاز كاميرا تستطيع مسح المستندات. يمكنك فتح ملف PDF موجود، أو المسح من iPhone أو iPad به كاميرا."
           : "This device has no camera that can scan documents. You can open an existing PDF, or scan on an iPhone or iPad with a camera."
    }
    static var deniedTitle: String { ar ? "الوصول إلى الكاميرا متوقف" : "Camera access is off" }
    static var deniedMessage: String {
        ar ? "اسمح لـ Xrero Office باستخدام الكاميرا من الإعدادات لمسح المستندات."
           : "Allow Xrero Office to use the camera in Settings to scan documents."
    }
    static var openSettings: String { ar ? "الإعدادات" : "Settings" }
    static var failedTitle: String { ar ? "تعذّر حفظ المسح" : "Couldn't save the scan" }
}
