import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let pipManager = PiPManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.requestIfNeeded()
    }
}
