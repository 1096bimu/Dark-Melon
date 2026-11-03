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
        // The editor shell fills the native content frame.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { EditorCommands() }
        #endif
        #if os(macOS)
        Settings { EditorSettingsView() }
            .windowStyle(.hiddenTitleBar)
        #endif
    }
}
