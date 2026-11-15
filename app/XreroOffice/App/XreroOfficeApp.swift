import SwiftUI

@main
struct XreroOfficeApp: App {
    /// Home Screen quick actions reach the app through its delegate (QuickActions.swift)
    @UIApplicationDelegateAdaptor(XRAppDelegate.self) private var appDelegate

    var body: some Scene {
        #if XR_AUTOTEST
        // CI build only (configuration "Autotest"): opens a fresh document straight in the editor for the UI tests
        // (XR_GALLERY=1: the template gallery first - TemplateGallery.swift, TemplateGalleryUITests; otherwise
        // AutotestRoot, QuickActions.swift: the test editor, or Home for the quick-action, scan and accessibility tests)
        WindowGroup {
            if ProcessInfo.processInfo.environment["XR_GALLERY"] == "1" { TemplateAutotestRoot() } else { AutotestRoot() }
        }
        #else
        WindowGroup { HomeScene().appLanguageEnvironment() }   // start screen; documents open over it (HomeScene.swift, DocumentOpener.swift)
        #endif
    }
}
