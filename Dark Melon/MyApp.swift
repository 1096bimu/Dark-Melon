import SwiftUI

@main struct MyApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(SaveLifecycleAppDelegate.self) private var appDelegate
    #endif
    var body: some Scene {
        WindowGroup(id: "editor") {
            ContentView()
        }
        #if os(macOS)
        // Keep one consistent title/toolbar row above all editor columns.
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { EditorCommands() }
        #endif
        #if os(macOS)
        Settings { EditorSettingsView() }
        #endif
    }
}
