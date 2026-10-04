import SwiftUI

@main
struct XreroOfficeApp: App {
    var body: some Scene {
        #if XR_AUTOTEST
        // CI build only (configuration "Autotest"): opens a fresh document straight in the editor for the UI tests
        WindowGroup { AutotestScreen() }
        #else
        DocumentGroup(newDocument: OfficeDocument(kind: .word)) { file in
            EditorScreen(document: file.$document, fileURL: file.fileURL)
        }
        #endif
    }
}
