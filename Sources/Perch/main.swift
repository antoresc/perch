import AppKit
import PerchCore

// Command-line switches, for setting up without opening the menu.
let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--install-hooks") {
    do {
        try HookInstaller.install()
        print("Claude hooks installed. Previous settings saved as \(PerchPaths.settingsBackup.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not install hooks: \(error)\n".utf8))
        exit(1)
    }
}
if arguments.contains("--remove-hooks") {
    do {
        try HookInstaller.remove()
        print("Claude hooks removed.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not remove hooks: \(error)\n".utf8))
        exit(1)
    }
}
if arguments.contains("--status") {
    print(HookInstaller.isInstalled() ? "hooks: installed" : "hooks: not installed")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var server: SocketServer?
    private var notch: NotchPanelController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0 != NSRunningApplication.current }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        let model = self.model
        let server = SocketServer(path: PerchPaths.socketPath) { message, fd in
            model.receive(message, fd: fd)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            let a = NSAlert()
            a.messageText = "Perch couldn't start listening"
            a.informativeText = "Sessions won't show up. (\(error))"
            a.runModal()
        }

        HookInstaller.refreshHelperIfNeeded()
        model.start()
        notch = NotchPanelController(model: model)
        menuBar = MenuBarController(model: model)
        model.openMenu = { [weak self] in self?.menuBar?.popUpAtMouse() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
