import AppKit
import BallScrollCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let store = SettingsStore()
    private let status = AppStatus()
    private let engine = ScrollEngine()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var frontmostBundleID: String?

    private let arguments = Set(CommandLine.arguments.dropFirst())

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        if anotherInstanceIsRunning() {
            NSApp.terminate(nil)
            return
        }

        engine.debugLogging = arguments.contains("--debug")
        PointerFreezer().restoreSystemDefault()

        setUpStatusItem()

        store.onChange = { [weak self] in self?.settingsChanged() }
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        pushConfig()

        if !Permissions.isTrusted, !arguments.contains("--no-prompt") {
            Permissions.prompt()
        }
        checkPermission()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPermission() }
        }

        if let snapshot = arguments.first(where: { $0.hasPrefix("--snapshot=") }) {
            showSettings()
            let path = String(snapshot.dropFirst("--snapshot=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.saveSettingsSnapshot(to: path)
                NSApp.terminate(nil)
            }
        } else if store.isFirstLaunch || arguments.contains("--settings") {
            showSettings()
        }
    }

    /// Development aid: save a picture of the settings window, for the README
    /// and for checking the layout without clicking through it.
    private func saveSettingsSnapshot(to path: String) {
        guard let window = settingsWindow, let view = window.contentView else { return }
        window.setContentSize(NSSize(width: view.fittingSize.width, height: min(view.fittingSize.height, 1400)))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    /// Opening the app again while it is running shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func anotherInstanceIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0 != me }
    }

    // MARK: - Engine state

    /// The engine can only run with Accessibility access, and must stop the
    /// moment access is withdrawn: a live event tap without access can stall
    /// the mouse for the whole system.
    private func checkPermission() {
        let trusted = Permissions.isTrusted
        if trusted, !engine.isRunning {
            status.engine = engine.start() ? .running : .failed
        } else if !trusted, engine.isRunning {
            engine.stop()
            status.engine = .needsPermission
        } else if !trusted {
            status.engine = .needsPermission
        }
        updateStatusIcon()
    }

    private func settingsChanged() {
        pushConfig()
        updateStatusIcon()
    }

    @objc private func frontmostAppChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        frontmostBundleID = app?.bundleIdentifier
        pushConfig()
        updateStatusIcon()
    }

    private func pushConfig() {
        let settings = store.settings
        let excluded = settings.excludedApps.first { $0.bundleID == frontmostBundleID }
        status.frontmostExcludedApp = excluded?.name
        engine.update(ScrollEngine.Config(
            settings: settings.scroll,
            trigger: settings.trigger,
            active: !settings.paused && excluded == nil
        ))
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let description: String
        if status.engine != .running {
            symbol = "exclamationmark.circle"
            description = "BallScroll needs attention"
        } else if store.settings.paused || status.frontmostExcludedApp != nil {
            symbol = "pause.circle"
            description = "BallScroll paused"
        } else {
            symbol = "arrow.up.and.down.circle"
            description = "BallScroll"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let headline: String
        switch status.engine {
        case .needsPermission: headline = "Needs Accessibility access"
        case .failed: headline = "Could not start. Quit and reopen."
        case .running:
            if store.settings.paused {
                headline = "Ball Scrolling is paused"
            } else if let app = status.frontmostExcludedApp {
                headline = "Off in \(app) (Excluded App)"
            } else {
                headline = "Ball Scrolling is on"
            }
        }
        let info = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        if status.engine == .needsPermission {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibilitySettings)))
        }
        let pause = item(store.settings.paused ? "Resume Ball Scrolling" : "Pause Ball Scrolling", #selector(togglePause))
        menu.addItem(pause)

        if let front = NSWorkspace.shared.frontmostApplication,
           let id = front.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let name = front.localizedName ?? id
            let isExcluded = store.settings.excludedApps.contains { $0.bundleID == id }
            let toggle = item(isExcluded ? "Stop Excluding \(name)" : "Exclude \(name)", #selector(toggleFrontmostExclusion(_:)))
            toggle.representedObject = ExcludedApp(bundleID: id, name: name)
            menu.addItem(toggle)
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit BallScroll", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePause() {
        store.settings.paused.toggle()
    }

    @objc private func toggleFrontmostExclusion(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? ExcludedApp else { return }
        if store.settings.excludedApps.contains(where: { $0.bundleID == app.bundleID }) {
            store.settings.excludedApps.removeAll { $0.bundleID == app.bundleID }
        } else {
            store.settings.excludedApps.append(app)
        }
    }

    @objc private func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings window

    @objc private func showSettings() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(store)
                .environmentObject(status)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "BallScroll Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
