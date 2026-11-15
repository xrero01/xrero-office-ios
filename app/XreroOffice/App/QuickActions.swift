import SwiftUI
import UIKit

/// Home Screen quick actions (plan S10): touch and hold the app icon for New document / New spreadsheet /
/// New presentation / Scan to PDF. The items themselves are static (Info.plist UIApplicationShortcutItems, Arabic
/// titles in ar.lproj/InfoPlist.strings), so they are there from the first install, before the app has ever run.
/// The chosen item reaches the app here and Home (HomeScene) runs it.
enum QuickAction: String, CaseIterable {
    case newDocument = "com.xrero.office.new-document"
    case newSpreadsheet = "com.xrero.office.new-spreadsheet"
    case newPresentation = "com.xrero.office.new-presentation"
    case scan = "com.xrero.office.scan"

    /// the full type, or its last part ("new-spreadsheet", "scan": the UI tests' XR_SHORTCUT)
    init?(id: String) {
        if let a = QuickAction(rawValue: id) { self = a; return }
        guard let a = QuickAction.allCases.first(where: { $0.rawValue.hasSuffix("." + id) }) else { return nil }
        self = a
    }

    /// the kind of new file the action makes (nil for Scan)
    var kind: OfficeKind? {
        switch self {
        case .newDocument: return .word
        case .newSpreadsheet: return .cell
        case .newPresentation: return .slide
        case .scan: return nil
        }
    }
}

/// Holds the quick action that was chosen until Home is on screen to run it (a cold launch delivers it before any view
/// exists).
final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()

    @Published private(set) var pending: QuickAction?
    /// this launch was started by a quick action (the CI test build then shows Home instead of its test editor)
    @Published private(set) var launchedFromShortcut = false

    /// `type` is UIApplicationShortcutItem.type. False for a type this app does not know.
    @discardableResult
    func receive(_ type: String, atLaunch: Bool = false) -> Bool {
        guard let action = QuickAction(id: type) else {
            NSLog("XR quick action unknown: %@", type)
            return false
        }
        NSLog("XR quick action %@%@", action.rawValue, atLaunch ? " (launch)" : "")
        let set = {
            if atLaunch { self.launchedFromShortcut = true }
            self.pending = action
        }
        if Thread.isMainThread { set() } else { DispatchQueue.main.async(execute: set) }
        return true
    }

    /// The pending action, once: Home calls this when it appears and whenever a new action arrives.
    func take() -> QuickAction? {
        let a = pending
        pending = nil
        return a
    }
}

/// The app delegate exists only to give the window scene a delegate that hears quick actions.
final class XRAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if XR_AUTOTEST
        // CI only: the same path a quick action takes, without the Home Screen (XR_SHORTCUT=new-spreadsheet, scan...)
        if let id = ProcessInfo.processInfo.environment["XR_SHORTCUT"] { QuickActionRouter.shared.receive(id, atLaunch: true) }
        #endif
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // cold launch: the quick action comes with the new scene's connection options
        if let item = options.shortcutItem { QuickActionRouter.shared.receive(item.type, atLaunch: true) }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = XRSceneDelegate.self
        return config
    }
}

/// Warm launch (the app was already running): the quick action is delivered to the scene.
final class XRSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickActionRouter.shared.receive(shortcutItem.type))
    }
}

#if XR_AUTOTEST
/// CI build root: the test editor (AutotestScreen) as before; the real Home when a test asks for it (XR_HOME=1) or the
/// launch came from a Home Screen quick action (the test that presses the real app icon).
struct AutotestRoot: View {
    @ObservedObject private var quick = QuickActionRouter.shared
    private let home = ProcessInfo.processInfo.environment["XR_HOME"] == "1"

    var body: some View {
        if home || quick.launchedFromShortcut {
            HomeScene().appLanguageEnvironment()
        } else {
            AutotestScreen()
        }
    }
}
#endif
