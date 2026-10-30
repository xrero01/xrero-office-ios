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
        // the editor's canvas colour (#F2F2F7 light / #000000 dark = systemGroupedBackground), so opening and the
        // light/dark switch show no white flash
        web.isOpaque = false
        web.backgroundColor = .systemGroupedBackground
        web.scrollView.backgroundColor = .systemGroupedBackground
        // live light / dark (M6): the editors follow iOS without a reload (a reload would lose undo and selection)
        web.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (_: WKWebView, _: UITraitCollection) in
            c.syncTheme()
        }
        // iOS flips the appearance of a backgrounded app to snapshot it for the app switcher (both looks): those
        // flips are ignored (syncTheme only acts while active) and the real appearance is checked on return
        c.activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                  object: nil, queue: .main) { [weak c] _ in c?.syncTheme() }
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
        // Only for crash recovery (webViewWebContentProcessDidTerminate below). No navigation-policy methods are
        // implemented, so loading, the xrero:// / ascdesktop:// schemes and links keep WebKit's default behaviour.
        web.navigationDelegate = c
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
        web.navigationDelegate = nil        // a closed editor must not reopen itself when its web process goes away
        web.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, PHPickerViewControllerDelegate {
        var parent: EditorWebView
        let resources = WebResources()
        weak var web: WKWebView?
        var offsetLock: NSKeyValueObservation?
        var loadedLang = ""
        /// "light" / "dark": the appearance the open editor really has (set at load, then only when the editor
        /// confirmed a live switch - so a switch that could not be delivered is retried, never lost)
        var loadedTheme = ""
        /// the live switch sent to the editor and not answered yet (no second refresh for the same change)
        private var themeInFlight = ""
        var activeObserver: NSObjectProtocol?
        deinit { if let o = activeObserver { NotificationCenter.default.removeObserver(o) } }
        private var pickReply: ((Any?, String?) -> Void)?
        var onSaved: (() -> Void)?

        init(_ parent: EditorWebView) { self.parent = parent }

        private var ready = false
        private var reloads = 0
        private var watchdog: DispatchWorkItem?
        /// The engine's own "document modified" mark (onDocumentModifiedChanged in xr-host.js -> "modified" 1/0).
        /// Kept here because once the web process is gone nobody can ask the engine any more.
        private var edited = false
        /// When the editor's web process died while the app was in use (see recoverFromTermination).
        private var terminations: [Date] = []
        /// Set while the last saved version is being reopened after a termination; reported once it is "ready".
        private var pendingRecovery: (edited: Bool, since: Date)?

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
            edited = false
            // a new editor page starts from nothing (after this view update: load() also runs inside one)
            let state = parent.controller.state
            DispatchQueue.main.async { state.reset() }
            armWatchdog()
            loadedLang = parent.lang
            loadedTheme = web.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            themeInFlight = ""
            resources.media.removeAll()
            web.configuration.userContentController.removeAllUserScripts()
            let ucc = web.configuration.userContentController
            ucc.addUserScript(WKUserScript(source: bridgeScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false))
            let acct = MainActor.assumeIsolated { XreroAccount.shared.webValue }     // the header's account chip
            ucc.addUserScript(WKUserScript(source: EditorController.accountScript(acct), injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
                exportFile: function (name, bytes) { return call({ cmd: 'export', name: name, data: b64(bytes) }); },
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
            case "export":
                // Save As: a copy in another format, written to a temporary folder and handed to the screen (share
                // sheet); the document's own file is not touched
                guard let n = body["name"] as? String, let s = body["data"] as? String, let d = Data(base64Encoded: s),
                      !d.isEmpty else { replyHandler(nil, "no data"); return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xr-export", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent((n as NSString).lastPathComponent)
                do { try d.write(to: url, options: .atomic) } catch { replyHandler(nil, "write failed"); return }
                replyHandler(true, nil)
                parent.onCommand("export", url.path)
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
                let p = body["p"] as? String ?? ""
                if c == "modified" { edited = p == "1" }          // O(1): this can arrive while typing
                // the state channel (xr-host.js "hub"): at most one diff per animation frame, applied to the
                // controller's EditorState only - not passed on to the screen, so it never re-renders the editor
                if c == "state" { parent.controller.state.apply(p); return }
                if c == "ready" { ready = true; watchdog?.cancel(); syncTheme() }   // a switch during loading
                if c == "copied" { copied(p); return }
                if c == "paste" { paste(); return }
                parent.onCommand(c, p)
                if c == "ready", let r = pendingRecovery {       // the reopened document is on screen again
                    pendingRecovery = nil
                    let ms = Int(Date().timeIntervalSince(r.since) * 1000)
                    NSLog("XR editor recovered in %ld ms", ms)
                    parent.onCommand("log", "recovered: last saved version back on screen in \(ms) ms")
                    parent.onCommand("recovered", r.edited ? "edited" : "")
                }
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

        // MARK: calls into the editor
        /// Runs `body` - the body of a JavaScript function, ending in `return <value>` when a result is wanted - inside
        /// the editor's IFRAME, where the engine and its API (window.__xrApi, Asc.editor) live; the app's own page
        /// around it only hosts that frame. The body runs as a function of the frame's own realm (its Function
        /// constructor), so `window`, `document` and every global in it are the editor's. `done` gets the value (a
        /// string, number, boolean, or array / object of those; nil for none) or an error text: "no editor frame",
        /// "error: <JS exception>", "js error: <WebKit>". Native code reaches the editor ONLY through this (also
        /// EditorController.call). Use it on a tap, never per keystroke.
        func call(_ body: String, _ done: ((Any?, String?) -> Void)? = nil) {
            guard let web else { done?(nil, "no editor"); return }
            // the body as a JS string literal (JSON-escaped inside a one-element array)
            let src = String(data: (try? JSONSerialization.data(withJSONObject: [body])) ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
            let js = """
            (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;if(!w||!w.Function)return {e:'no editor frame'};
             try{var v=(new w.Function(\(src)[0])).call(w);return {v:(v===undefined?null:v)};}
             catch(e){return {e:'error: '+(e&&e.message||e)};}})()
            """
            web.evaluateJavaScript(js) { result, error in
                if let error { done?(nil, "js error: \(error.localizedDescription)"); return }
                let o = result as? [String: Any]
                if let e = o?["e"] as? String { done?(nil, e); return }
                let v = o?["v"]
                done?(v is NSNull ? nil : v, nil)
            }
        }

        /// iOS switched light / dark (or the app came back / the editor became ready): tell the editor frame the way
        /// the desktop shell does (Desktop.js 'renderervars:changed' -> Themes.refreshTheme, which swaps the theme in
        /// place). Only while the app is active and the editor is ready, once per real change; never on the
        /// keystroke path.
        func syncTheme() {
            guard let web, ready else { return }
            let active = MainActor.assumeIsolated { UIApplication.shared.applicationState == .active }
            guard active else { return }
            let t = web.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            guard t != loadedTheme, t != themeInFlight else { return }
            themeInFlight = t
            let js = "(function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;" +
                "if(!w||!w.on_native_message)return 'no editor frame';" +
                "w.on_native_message('renderervars:changed',JSON.stringify({theme:{system:'\(t)'}}));return 'ok';})()"
            web.evaluateJavaScript(js) { [weak self] result, error in
                guard let self else { return }
                let r = (result as? String) ?? error?.localizedDescription ?? "?"
                if self.themeInFlight == t { self.themeInFlight = "" }
                if r == "ok" { self.loadedTheme = t }          // otherwise the next trait change / ready retries
                self.parent.onCommand("log", "appearance \(t): " + r)
                if r == "ok" { self.syncTheme() }              // the appearance flipped again meanwhile
            }
        }

        /// Save As: the format picked in the app's list ('' = cancelled) goes back to xr-host.js, which converts the
        /// copy and sends it as an "export" message.
        func answerSaveAs(_ ext: String) {
            let safe = ext.filter { $0.isLetter || $0.isNumber }
            call("return window.__xrSaveAs ? __xrSaveAs('\(safe)') : 'no save as';") { [weak self] result, error in
                self?.parent.onCommand("log", "save as answer \(safe.isEmpty ? "(cancel)" : safe): " +
                    ((result as? String) ?? error ?? "?"))
            }
        }

        /// Runs the editor's own Save (the same as Ctrl+S): engine -> x2t -> "save" message above.
        /// Saves the document as it is now, changed or not (the desktop's own save entry point: engine -> x2t ->
        /// the "save" message). Used for the app going to the background, Share and the EN/AR switch.
        func requestSave(onlyIfModified: Bool = false, then done: (() -> Void)? = nil) {
            onSaved = done
            let check = onlyIfModified ? """
             try{ var a=w.Asc&&w.Asc.editor||w.editor; if(a){ var m=a.isDocumentModified?a.isDocumentModified():(a.asc_isDocumentModified?a.asc_isDocumentModified():true); if(!m)return 'unmodified'; } }catch(e){}
            """ : ""
            let js = """
            var w=window;\(check)
            if(w.DesktopOfflineAppDocumentStartSave){w.DesktopOfflineAppDocumentStartSave(false);return 'ok';}
            if(w.AscDesktopEditor_Save){w.AscDesktopEditor_Save();return 'ok';} return 'no save entry';
            """
            call(js) { [weak self] result, error in
                let r = (result as? String) ?? error ?? "?"
                self?.parent.onCommand("log", "native save request: " + r)
                if r != "ok" { self?.onSaved?(); self?.onSaved = nil }
            }
        }

        // MARK: crash recovery
        /// iOS ends the editor's web process when it needs the memory (a big document on a small device) or when it
        /// crashes; the web view is then blank and the user's work looks lost. Reopen the editor with the last saved
        /// version (parent.document.data - what the "open" message hands the editor) and let the screen say so once
        /// it is back. If the document itself keeps taking the process down - a second end within 60 s while the app
        /// is in use - reopening would only loop: stop and let the screen offer Share and Back instead.
        /// Also called directly by the CI autotest when it cannot end the process itself.
        func recoverFromTermination() {
            let now = Date()
            // ends while the app is in the background (iOS reclaiming memory) are not the document's fault
            let active = MainActor.assumeIsolated { UIApplication.shared.applicationState != .background }
            if active { terminations = terminations.filter { now.timeIntervalSince($0) < 60 } + [now] }
            let lostEdits = edited || (pendingRecovery?.edited ?? false)
            // a save that was running in the dead page can never finish: let whoever waits for it (Share, the
            // language switch) carry on with the last saved version instead of waiting forever
            if let done = onSaved { onSaved = nil; done() }
            if terminations.count >= 2 {
                pendingRecovery = nil
                watchdog?.cancel()
                NSLog("XR editor web process ended twice within 60 s - not reopening")
                parent.onCommand("log", "web process ended \(terminations.count)x within 60 s - not reopening (too large)")
                parent.onCommand("too-large", "")
                return
            }
            NSLog("XR editor web process ended (app active=%ld) - reopening the last saved version", active ? 1 : 0)
            parent.onCommand("log", "web process ended (app active=\(active), unsaved edits=\(lostEdits)) - reopening the last saved version")
            pendingRecovery = (lostEdits, pendingRecovery?.since ?? now)
            load()
        }

        // MARK: clipboard (the editors' Cut / Copy / Paste, see "clipboard" in xr-host.js)

        /// After Copy / Cut: WebKit normally wrote the pasteboard itself (text + HTML). When it could not
        /// (ok == false), the plain text goes there from here so the copy still reaches other apps and Paste.
        private func copied(_ json: String) {
            guard let d = json.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
            let ok = (o["ok"] as? Bool) ?? false
            let text = (o["text"] as? String) ?? ""
            if !ok && !text.isEmpty { UIPasteboard.general.string = text }
            parent.onCommand("log", "copy: " + (ok ? "pasteboard written by the editor" : (text.isEmpty ? "nothing selected" : "plain text written by the app")))
        }

        /// Paste: the pasteboard is read only here, on the user's own Paste tap - never on launch or on becoming
        /// active - so iOS shows its "Allow Paste" question only when the user really pastes from another app.
        /// Phase 1: plain text (Xrero's own copies come back with full formatting from the editor's internal format).
        private func paste() {
            let pb = UIPasteboard.general
            guard pb.hasStrings, let text = pb.string, !text.isEmpty else { pasteDone("empty"); return }
            // the text as a JS string literal (JSON-escaped inside a one-element array)
            let arg = String(data: (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[null]".utf8), encoding: .utf8) ?? "[null]"
            call("return window.__xrPaste ? __xrPaste(\(arg)[0]) : 'no editor';") { [weak self] result, error in
                self?.pasteDone((result as? String) ?? error ?? "?")
            }
        }

        private func pasteDone(_ result: String) {
            parent.onCommand("log", "paste: " + result)
            if result != "internal" && result != "text" { parent.onCommand("paste-failed", result) }
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

/// The web view's navigation delegate, for one event only. (Declared in an extension so the coordinator's own
/// isolation stays as it is.)
extension EditorWebView.Coordinator: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recoverFromTermination()
    }
}

/// Lets SwiftUI talk to the web editor: save (share, language switch, app going to the background), run a command
/// in it (call) and follow its state (state).
final class EditorController: ObservableObject {
    weak var coordinator: EditorWebView.Coordinator?
    /// The editor's live state (undo / redo, modified / saved, selection, text format, title). Views that show it
    /// observe this object themselves (@ObservedObject var state: EditorState): it is deliberately not republished
    /// through the controller, so a caret move never re-renders the whole editor screen.
    let state = EditorState()

    /// Runs a JavaScript function body in the editor frame (see Coordinator.call) - the one way native controls
    /// reach the engine, e.g. `call("__xrApi.put_TextPrBold(true)")`. On a tap only, never per keystroke.
    func call(_ body: String, _ done: ((Any?, String?) -> Void)? = nil) {
        if let c = coordinator { c.call(body, done) } else { done?(nil, "no editor") }
    }

    /// localStorage "xr-acct" = the account the editors' header shows (its chip re-reads it every 0.8 s).
    static func accountScript(_ json: String) -> String {
        "try{localStorage.setItem('xr-acct', JSON.stringify(\(json)))}catch(e){}"
    }

    func syncAccount(_ json: String) {
        coordinator?.web?.evaluateJavaScript(EditorController.accountScript(json), completionHandler: nil)
    }
    func answerSaveAs(_ ext: String) { coordinator?.answerSaveAs(ext) }
    func save(onlyIfModified: Bool = false, then done: (() -> Void)? = nil) {
        if let c = coordinator { c.requestSave(onlyIfModified: onlyIfModified, then: done) } else { done?() }
    }
}
