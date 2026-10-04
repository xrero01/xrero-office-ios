import Foundation
import WebKit

/// Serves the editors from the app bundle without a server:
///   xrero://app/<path>          bundle "web/<path>" (editors, x2t WebAssembly, host scripts)
///   xrero://app/fonts/<id>      the app's font files (fonts-gen/fonts) ; also ascdesktop://fonts/<id>
///   xrero://app/__fontsprite    font-picker previews (fonts-gen/images)
///   xrero://media/<name>        pictures of the open document (filled by the editor through the bridge)
/// editors/sdkjs/common/AllFonts.js is the app's own font list (fonts-gen/AllFonts.js).
final class WebResources: NSObject, WKURLSchemeHandler {
    let root = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
    var media: [String: Data] = [:]                  // main thread only
    private var stopped = Set<ObjectIdentifier>()    // main thread only
    private let io = DispatchQueue(label: "xrero.web.io", qos: .userInitiated, attributes: .concurrent)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let id = ObjectIdentifier(task)
        stopped.remove(id)
        if url.host == "media" {
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            finish(task, id, media[name], url)
            return
        }
        let file = localFile(for: url)
        io.async {
            let data = file.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            DispatchQueue.main.async { self.finish(task, id, data, url) }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ data: Data?, _ url: URL) {
        if stopped.remove(id) != nil { return }
        let body = data ?? Data("not found".utf8)
        let headers = ["Content-Type": data == nil ? "text/plain" : WebResources.mime(url.pathExtension),
                       "Content-Length": String(body.count),
                       "Access-Control-Allow-Origin": "*",
                       "Cache-Control": "no-cache"]
        let response = HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    private func localFile(for url: URL) -> URL? {
        var path = url.path                                   // "/editors/..." ("" + "/<id>" for ascdesktop://fonts/<id>)
        if url.scheme == "ascdesktop" { path = "/" + (url.host ?? "") + path }
        if path.hasPrefix("/fonts/") {
            return root.appendingPathComponent("fonts-gen/fonts").appendingPathComponent((path as NSString).lastPathComponent)
        }
        if path == "/__fontsprite" {
            let scale = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "s" }?.value ?? ""
            let safe = scale.filter { "0123456789.@x_ea".contains($0) }
            return root.appendingPathComponent("fonts-gen/images/fonts_thumbnail\(safe).png")
        }
        if path == "/editors/sdkjs/common/AllFonts.js" {
            return root.appendingPathComponent("fonts-gen/AllFonts.js")
        }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        return file.path.hasPrefix(root.standardizedFileURL.path) ? file : nil
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "emf", "wmf": return "image/x-emf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "xml": return "application/xml"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
