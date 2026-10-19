import SwiftUI

@main struct MyApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(SaveLifecycleAppDelegate.self) private var appDelegate
    #endif
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .commands { EditorCommands() }
        #endif
        #if os(macOS)
        Settings { EditorSettingsView() }
        #endif
    }
}
