import SwiftUI
import WebKit
import PhotosUI
import UniformTypeIdentifiers

/// The Xrero web editors in a WKWebView, wired to the document through window.XreroHost (see web/xr-host.js).
struct EditorWebView: UIViewRepresentable {
    @Binding var document: OfficeDocument
    var title: String
    var lang: String
    var onCommand: (String, String) -> Void
    var controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let c = context.coordinator
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(c.resources, forURLScheme: "xrero")
        config.setURLSchemeHandler(c.resources, forURLScheme: "ascdesktop")
        config.suppressesIncrementalRendering = false
        config.userContentController.addScriptMessageHandler(c, contentWorld: .page, name: "xr")   // scripts: load()

        let web = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.scrollView.isScrollEnabled = false        // the editors scroll their own canvas
        web.allowsLinkPreview = false
        // When the keyboard opens, WebKit scrolls the page to reveal the editor's hidden input field, which slides
        // the whole editor sideways on a phone. The page itself never needs to scroll: keep it at the origin.
        c.offsetLock = web.scrollView.observe(\.contentOffset, options: [.new]) { sv, _ in
            if sv.contentOffset != .zero { sv.contentOffset = .zero }
        }
        c.web = web
        controller.coordinator = c
        c.load()
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        controller.coordinator = c
        if c.loadedLang != lang { c.load() }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, PHPickerViewControllerDelegate {
        var parent: EditorWebView
        let resources = WebResources()
        weak var web: WKWebView?
        var offsetLock: NSKeyValueObservation?
        var loadedLang = ""
        private var pickReply: ((Any?, String?) -> Void)?
        var onSaved: (() -> Void)?

        init(_ parent: EditorWebView) { self.parent = parent }

        private var ready = false
        private var reloads = 0
        private var watchdog: DispatchWorkItem?

        /// The web editors occasionally lose a script-loading race in WebKit and never start (seen on Slides).
        /// Nothing is open at that point, so reload (twice at most) when "ready" has not arrived in time.
        private func armWatchdog() {
            watchdog?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.ready, self.reloads < 2 else { return }
                self.reloads += 1
                self.parent.onCommand("log", "editor not ready after 40 s - reloading (\(self.reloads))")
                self.load(keepReloadCount: true)
            }
            watchdog = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: item)
        }

        func load(keepReloadCount: Bool = false) {
            guard let web else { return }
            if !keepReloadCount { reloads = 0 }
            ready = false
            armWatchdog()
            loadedLang = parent.lang
            resources.media.removeAll()
            web.configuration.userContentController.removeAllUserScripts()
            let ucc = web.configuration.userContentController
            ucc.addUserScript(WKUserScript(source: bridgeScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false))
            if let host = try? String(contentsOf: resources.root.appendingPathComponent("xr-host.js"), encoding: .utf8) {
                ucc.addUserScript(WKUserScript(source: host, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            var c = URLComponents(string: "xrero://app/editors/web-apps/apps/api/documents/xr-editor.html")!
            c.queryItems = [URLQueryItem(name: "doctype", value: parent.document.kind.rawValue),
                            URLQueryItem(name: "title", value: parent.title),
                            URLQueryItem(name: "lang", value: parent.lang),
                            URLQueryItem(name: "theme", value: web.traitCollection.userInterfaceStyle == .dark ? "dark" : "light")]
            web.load(URLRequest(url: c.url!))
        }

        /// window.XreroHost for every frame: the JS half of the bridge (xr-host.js uses it).
        func bridgeScript() -> String {
            let cfg: [String: String] = ["lang": parent.lang, "title": parent.title,
                                         "theme": (web?.traitCollection.userInterfaceStyle == .dark) ? "dark" : "light"]
            let json = String(data: (try? JSONSerialization.data(withJSONObject: cfg)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            return """
            (function () {
              if (window.XreroHost) return;
              var mh = window.webkit && webkit.messageHandlers && webkit.messageHandlers.xr;
              if (!mh) return;
              var cfg = \(json);
              function call(o) { return mh.postMessage(o); }
              function b64(buf) { var u = buf instanceof Uint8Array ? buf : new Uint8Array(buf), s = '', CH = 0x8000;
                for (var i = 0; i < u.length; i += CH) s += String.fromCharCode.apply(null, u.subarray(i, i + CH)); return btoa(s); }
              function unb64(s) { var r = atob(s), u = new Uint8Array(r.length); for (var i = 0; i < r.length; i++) u[i] = r.charCodeAt(i); return u.buffer; }
              window.XreroHost = {
                lang: cfg.lang, theme: cfg.theme, title: cfg.title,
                openFile: function () { return call({ cmd: 'open' }).then(function (r) { return { name: r.name, data: unb64(r.data) }; }); },
                saveFile: function (name, bytes) { return call({ cmd: 'save', name: name, data: b64(bytes) }); },
                putMedia: function (name, bytes) { return call({ cmd: 'media', name: name, data: b64(bytes) }); },
                mediaUrl: function (name) { return 'xrero://media/' + encodeURIComponent(name); },
                x2tBase: 'xrero://app/x2t/',
                fontUrl: function (id) { return 'xrero://app/fonts/' + encodeURIComponent(id); },
                fontsSprite: function (s) { return 'xrero://app/__fontsprite?s=' + encodeURIComponent(s || ''); },
                pickFile: function (filter) { return call({ cmd: 'pick', filter: String(filter || '') }).then(function (r) { return r ? { name: r.name, data: unb64(r.data) } : null; }); },
                command: function (c, p) { call({ cmd: 'ui', c: String(c), p: String(p || '') }); },
                log: function (m) { call({ cmd: 'log', m: String(m) }); }
              };
            })();
            """
        }

        // MARK: messages from the editors
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
                replyHandler(nil, "bad message"); return
            }
            switch cmd {
            case "open":
                replyHandler(["name": parent.title, "data": parent.document.data.base64EncodedString()], nil)
            case "save":
                guard let s = body["data"] as? String, let d = Data(base64Encoded: s), !d.isEmpty else {
                    replyHandler(nil, "no data"); return
                }
                parent.document.data = d            // DocumentGroup writes it to the file
                replyHandler(true, nil)
                parent.onCommand("saved", String(d.count))
                onSaved?(); onSaved = nil
            case "media":
                if let n = body["name"] as? String, let s = body["data"] as? String, let d = Data(base64Encoded: s) {
                    resources.media[n] = d
                }
                replyHandler(true, nil)
            case "pick":
                pickReply = replyHandler
                presentPhotoPicker()
            case "ui":
                replyHandler(nil, nil)
                let c = body["c"] as? String ?? ""
                if c == "ready" { ready = true; watchdog?.cancel() }
                parent.onCommand(c, body["p"] as? String ?? "")
            case "log":
                replyHandler(nil, nil)
                #if DEBUG
                print("[xr]", body["m"] as? String ?? "")
                #endif
                parent.onCommand("log", body["m"] as? String ?? "")
            default:
                replyHandler(nil, "unknown command")
            }
        }

        /// Runs the editor's own Save (the same as Ctrl+S): engine -> x2t -> "save" message above.
        /// Saves the document as it is now, changed or not (the desktop's own save entry point: engine -> x2t ->
        /// the "save" message). Used for the app going to the background, Share and the EN/AR switch.
        func requestSave(then done: (() -> Void)? = nil) {
            onSaved = done
            let js = """
            (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;if(!w)return 'no editor frame';
             try{ if(w.DesktopOfflineAppDocumentStartSave){w.DesktopOfflineAppDocumentStartSave(false);return 'ok';}
                  if(w.AscDesktopEditor_Save){w.AscDesktopEditor_Save();return 'ok';} return 'no save entry'; }
             catch(e){ return 'error: '+e; }})()
            """
            web?.evaluateJavaScript(js) { [weak self] result, error in
                let r = (result as? String) ?? (error.map { "js error: \($0.localizedDescription)" } ?? "?")
                self?.parent.onCommand("log", "native save request: " + r)
                if r != "ok" { self?.onSaved?(); self?.onSaved = nil }
            }
        }

        // MARK: pictures
        private func presentPhotoPicker() {
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            topController()?.present(picker, animated: true)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let reply = pickReply else { return }
            pickReply = nil
            guard let provider = results.first?.itemProvider else { reply(NSNull(), nil); return }
            let type = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.first { $0.conforms(to: .png) || $0.conforms(to: .jpeg) } ?? .jpeg
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                var bytes = data
                var ext = type.preferredFilenameExtension ?? "jpg"
                if bytes == nil || !(type.conforms(to: .png) || type.conforms(to: .jpeg)), let d = data, let img = UIImage(data: d) {
                    bytes = img.jpegData(compressionQuality: 0.9); ext = "jpg"   // HEIC etc. -> JPEG the document can hold
                }
                DispatchQueue.main.async {
                    if let b = bytes { reply(["name": "image." + ext, "data": b.base64EncodedString()], nil) } else { reply(NSNull(), nil) }
                }
            }
        }

        private func topController() -> UIViewController? {
            var vc = web?.window?.rootViewController
            while let p = vc?.presentedViewController { vc = p }
            return vc
        }
    }
}

/// Lets SwiftUI ask the web editor to save (share, language switch, app going to the background).
final class EditorController: ObservableObject {
    weak var coordinator: EditorWebView.Coordinator?
    func save(then done: (() -> Void)? = nil) {
        if let c = coordinator { c.requestSave(then: done) } else { done?() }
    }
}
