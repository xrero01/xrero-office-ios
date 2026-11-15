import SwiftUI

@main
struct XreroOfficeApp: App {
    /// Home Screen quick actions reach the app through its delegate (QuickActions.swift)
    @UIApplicationDelegateAdaptor(XRAppDelegate.self) private var appDelegate

    var body: some Scene {
        #if XR_AUTOTEST
        // CI build only (configuration "Autotest"): opens a fresh document straight in the editor for the UI tests
        // (Home instead for the quick-action and scan tests: AutotestRoot, QuickActions.swift)
        WindowGroup { AutotestRoot() }
        #else
        WindowGroup { HomeScene().appLanguageEnvironment() }   // start screen; documents open over it (HomeScene.swift, DocumentOpener.swift)
        #endif
    }
}
