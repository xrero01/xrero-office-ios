import SwiftUI

@main
struct XreroOfficeApp: App {
    var body: some Scene {
        #if XR_AUTOTEST
        // CI build only (configuration "Autotest"): opens a fresh document straight in the editor for the UI tests
        // XR_HOME=1: the real start screen instead (the accessibility test, plan S12)
        WindowGroup {
            if ProcessInfo.processInfo.environment["XR_HOME"] == "1" { HomeScene().appLanguageEnvironment() }
            else { AutotestScreen() }
        }
        #else
        WindowGroup { HomeScene().appLanguageEnvironment() }   // start screen; documents open over it (HomeScene.swift, DocumentOpener.swift)
        #endif
    }
}
