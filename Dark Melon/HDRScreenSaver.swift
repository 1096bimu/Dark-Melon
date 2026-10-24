#if os(macOS)
import SwiftUI
import AppKit
import CoreGraphics

extension EnvironmentValues {
    @Entry var hdrScreenSaverActive = false
}

/// Presentation only: the selected rendition and development settings never change.
struct HDRScreenSaver: ViewModifier {
    static let preferenceKey = "hdrScreenSaverEnabled"
    static let idleTimeout: TimeInterval = 60
    @AppStorage(Self.preferenceKey) private var enabled = false
    @State private var active = true
    @State private var idle = false

    func body(content: Content) -> some View {
        content
            .environment(\.hdrScreenSaverActive, enabled && (!active || idle))
            .onAppear { active = NSApp.isActive }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                active = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                active = true
                idle = false
            }
            .task(id: enabled) {
                guard enabled else { idle = false; return }
                while !Task.isCancelled {
                    // Any session input, without event taps or input-monitoring permission.
                    let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                        eventType: CGEventType(rawValue: UInt32.max)!)
                    idle = seconds >= Self.idleTimeout
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                }
            }
    }
}
#endif
