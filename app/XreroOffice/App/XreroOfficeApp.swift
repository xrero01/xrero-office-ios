import SwiftUI

@main
struct XreroOfficeApp: App {
    var body: some Scene {
        #if XR_AUTOTEST
        // CI build only (configuration "Autotest"): opens a fresh document straight in the editor for the UI tests
        // (XR_GALLERY=1: the template gallery first - TemplateGallery.swift, TemplateGalleryUITests)
        WindowGroup {
            if ProcessInfo.processInfo.environment["XR_GALLERY"] == "1" { TemplateAutotestRoot() } else { AutotestScreen() }
        }
        #else
        WindowGroup { HomeScene().appLanguageEnvironment() }   // start screen; documents open over it (HomeScene.swift, DocumentOpener.swift)
        #endif
    }
}
