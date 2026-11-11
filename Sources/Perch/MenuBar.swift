import AppKit
import PerchCore
import ServiceManagement

/// The bird icon and its menu, plus the divider that tucks other menu bar icons away.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let mainItem: NSStatusItem
    private let divider: NSStatusItem
    private let menu = NSMenu()
    private let defaults = UserDefaults.standard

    private static let dividerShown: CGFloat = 12
    private static let dividerHiding: CGFloat = 10_000

    private var tucked: Bool {
        get { defaults.bool(forKey: "tucked") }
        set { defaults.set(newValue, forKey: "tucked") }
    }

    init(model: AppModel) {
        self.model = model
        // Created first so it ends up on the right; the divider is added to its left.
        mainItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        divider = NSStatusBar.system.statusItem(withLength: Self.dividerShown)
        super.init()

        mainItem.autosaveName = "PerchMain"
        divider.autosaveName = "PerchDivider"

        if let button = mainItem.button {
            let image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Perch")
                ?? NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Perch")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Perch — Option-click to hide or show tucked icons"
        }
        menu.delegate = self
        applyDivider(hiding: false)

        // Positions are only known once the menu bar has laid itself out.
        if tucked {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.setTucked(true, warn: false) }
            }
        }
    }

    // MARK: Clicks

    @objc private func clicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            setTucked(!isHiding, warn: true)
            return
        }
        mainItem.menu = menu
        mainItem.button?.performClick(nil)
        mainItem.menu = nil
    }

    /// Shows the same menu at the mouse position, for the button inside the notch panel.
    func popUpAtMouse() {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: Tucking icons away

    private var isHiding: Bool { divider.length > Self.dividerShown }

    private var dividerIsLeftOfBird: Bool {
        guard let d = divider.button?.window?.frame, let m = mainItem.button?.window?.frame else { return false }
        return d.minX < m.minX
    }

    private func applyDivider(hiding: Bool) {
        divider.length = hiding ? Self.dividerHiding : Self.dividerShown
        if hiding {
            divider.button?.image = nil
        } else {
            let image = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: "Perch divider")
            image?.isTemplate = true
            divider.button?.image = image
            divider.button?.toolTip = "Hold ⌘ and drag icons to the left of this line to tuck them away"
        }
    }

    private func setTucked(_ hide: Bool, warn: Bool) {
        if hide && !dividerIsLeftOfBird {
            // Hiding now would push the bird off screen too, with no way back.
            if warn {
                alert("Move the divider first",
                      "Hold ⌘ and drag the thin ‹ divider so it sits to the left of the bird. Icons to the left of the divider are the ones that get hidden.")
            }
            tucked = false
            return
        }
        applyDivider(hiding: hide)
        tucked = hide
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let count = model.sessions.count
        menu.addItem(info(count == 0 ? "No Claude sessions running" : "\(count) Claude session\(count == 1 ? "" : "s")"))
        let u = model.usage
        menu.addItem(info("Last 5 hours: \(TokenFormat.short(u.last5h.fresh)) tokens"))
        menu.addItem(info("Today: \(TokenFormat.short(u.today.fresh)) tokens  (+\(TokenFormat.short(u.today.cacheRead)) cached re-reads)"))
        menu.addItem(.separator())

        menu.addItem(item(isHiding ? "Show Tucked Icons" : "Hide Icons Left of the ‹ Divider", #selector(toggleTucked)))
        menu.addItem(.separator())

        let soundMenu = NSMenu()
        let none = item("None", #selector(pickSound(_:)))
        none.representedObject = ""
        none.state = model.soundName.isEmpty ? .on : .off
        soundMenu.addItem(none)
        soundMenu.addItem(.separator())
        for name in AppModel.sounds {
            let i = item(name, #selector(pickSound(_:)))
            i.representedObject = name
            i.state = model.soundName == name ? .on : .off
            soundMenu.addItem(i)
        }
        let soundItem = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        let panel = item("Show Notch Panel", #selector(togglePanel))
        panel.state = model.showPanel ? .on : .off
        menu.addItem(panel)

        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        if HookInstaller.isInstalled() {
            menu.addItem(info("Claude hooks: installed"))
            menu.addItem(item("Remove Claude Hooks", #selector(removeHooks)))
        } else {
            menu.addItem(info("Claude hooks: not installed"))
            menu.addItem(item("Install Claude Hooks", #selector(installHooks)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Perch", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: Actions

    @objc private func toggleTucked() { setTucked(!isHiding, warn: true) }

    @objc private func pickSound(_ sender: NSMenuItem) {
        model.soundName = sender.representedObject as? String ?? ""
        model.playSound()
    }

    @objc private func togglePanel() { model.showPanel.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Open at Login", error.localizedDescription)
        }
    }

    @objc private func installHooks() {
        do {
            try HookInstaller.install()
            alert("Claude hooks installed",
                  "New Claude Code sessions will show up in Perch. Sessions that are already open need a restart. Your previous settings were saved as settings.json.before-perch.")
        } catch {
            alert("Couldn't install hooks", "\(error)")
        }
    }

    @objc private func removeHooks() {
        do {
            try HookInstaller.remove()
        } catch {
            alert("Couldn't remove hooks", "\(error)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
