import AppKit
@testable import Dark_Melon

@main struct FileOpenRequestsChecks {
    @MainActor static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let router = FileOpenRequests.shared
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.arw")
        let third = URL(fileURLWithPath: "/tmp/third.heic")
        router.receive([URL(string: "https://example.com")!])
        assert(router.pendingURL == nil)
        router.receive([first])
        assert(router.pendingURL == first, "Startup file was dropped")
        var opened: [URL] = []
        var reopenCount = 0
        let coordinator = FileSaveLifecycle.Coordinator(approveClose: { true }, openFile: { opened.append($0) }, openEditor: { reopenCount += 1 })
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:100,height:100), styleMask:[.titled], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false
        coordinator.attach(to:window)
        try? await Task.sleep(for:.milliseconds(50))
        assert(opened == [first] && router.pendingURL == nil, "Startup request not delivered once editor attached")
        SaveLifecycleAppDelegate().application(app,open:[second])
        assert(opened == [first,second] && router.pendingURL == nil, "Delegate did not route to open editor")
        window.close()
        window.delegate = nil
        router.receive([third])
        assert(reopenCount == 1 && router.pendingURL == third, "Closed editor did not retain request and ask to reopen")
        let next = NSWindow(contentRect:NSRect(x:0,y:0,width:100,height:100), styleMask:[.titled], backing:.buffered, defer:false)
        next.isReleasedWhenClosed = false
        let replacement = FileSaveLifecycle.Coordinator(approveClose:{true},openFile:{opened.append($0)},openEditor:{})
        replacement.attach(to:next)
        try? await Task.sleep(for:.milliseconds(50))
        assert(opened == [first,second,third] && router.pendingURL == nil)
        next.close()
        print("PASS: delegate delivery, retained cold-start file, existing editor routing, and reopen after closing editor")
    }
}
