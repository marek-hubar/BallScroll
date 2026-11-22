import AppKit
import BallScrollCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var status: AppStatus
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            if status.engine != .running {
                permissionSection
            }
            generalSection
            feelSection
            directionSection
            momentumSection
            excludedAppsSection
            Section {
                HStack {
                    Spacer()
                    Button("Restore Default Feel") {
                        store.settings.scroll = ScrollSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560, idealHeight: 720)
    }

    // MARK: - Sections

    private var permissionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    status.engine == .failed ? "BallScroll could not start" : "Accessibility access needed",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(.orange)
                Text(status.engine == .failed
                    ? "Access is granted, but macOS did not let BallScroll watch the mouse. Quit and reopen BallScroll."
                    : "BallScroll needs Accessibility access to watch the Trigger Button and send scroll events. Switch it on for BallScroll in System Settings; it starts working right away.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                Button("Open Accessibility Settings") {
                    Permissions.openAccessibilitySettings()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Ball Scrolling", isOn: Binding(
                get: { !store.settings.paused },
                set: { store.settings.paused = !$0 }
            ))
            Picker("Trigger Button", selection: $store.settings.trigger) {
                ForEach(TriggerButton.allCases) { button in
                    Text(button.displayName).tag(button)
                }
            }
            Toggle("Open at login", isOn: Binding(
                get: { launchAtLogin },
                set: { wanted in
                    loginItemError = LoginItem.set(enabled: wanted)
                    launchAtLogin = LoginItem.isEnabled
                }
            ))
            .disabled(!LoginItem.isAvailable)
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            } else if !LoginItem.isAvailable {
                Text("Available when BallScroll runs as an app from the Applications folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var feelSection: some View {
        Section {
            SliderRow(
                title: "Speed",
                value: $store.settings.scroll.speed,
                range: 0.25...8, step: 0.25,
                format: { String(format: "%.2f px per count", $0) }
            )
            SliderRow(
                title: "Acceleration",
                value: $store.settings.scroll.acceleration,
                range: 0...2, step: 0.05,
                format: { $0 == 0 ? "Off" : String(format: "%.2f", $0) }
            )
            SliderRow(
                title: "Smoothing",
                value: $store.settings.scroll.smoothing,
                range: 0...0.1, step: 0.005,
                format: { $0 == 0 ? "Off" : String(format: "%.0f ms", $0 * 1000) }
            )
            SliderRow(
                title: "Dead Zone",
                value: $store.settings.scroll.deadZone,
                range: 0...20, step: 1,
                format: { $0 == 0 ? "Off" : String(format: "%.0f counts", $0) }
            )
        } header: {
            Text("Feel")
        } footer: {
            Text("Acceleration scrolls further when the ball moves fast. Smoothing spreads each ball movement over a few frames, trading a little delay for softer motion. The Dead Zone is how far the ball may move before a press turns into scrolling; with it off, any movement scrolls.")
        }
    }

    private var directionSection: some View {
        Section {
            Toggle("Axis Lock", isOn: $store.settings.scroll.axisLock)
            Toggle("Reverse vertical", isOn: $store.settings.scroll.reverseVertical)
            Toggle("Reverse horizontal", isOn: $store.settings.scroll.reverseHorizontal)
        } header: {
            Text("Direction")
        } footer: {
            Text("Axis Lock keeps each scroll on the axis the ball first moved along. By default the content follows the ball, like dragging the page.")
        }
    }

    private var momentumSection: some View {
        Section {
            Toggle("Momentum", isOn: $store.settings.scroll.momentum)
            SliderRow(
                title: "Glide",
                value: $store.settings.scroll.momentumGlide,
                range: 0.1...0.9, step: 0.05,
                format: { String(format: "%.2f s", $0) }
            )
            .disabled(!store.settings.scroll.momentum)
        } header: {
            Text("Momentum")
        } footer: {
            Text("With Momentum on, releasing the Trigger Button while the ball is still rolling lets the content glide to a stop. Touching the ball again stops the glide.")
        }
    }

    private var excludedAppsSection: some View {
        Section {
            if store.settings.excludedApps.isEmpty {
                Text("No Excluded Apps").foregroundStyle(.secondary)
            }
            ForEach(store.settings.excludedApps) { app in
                HStack {
                    Image(nsImage: AppCatalog.icon(forBundleID: app.bundleID))
                        .resizable().frame(width: 20, height: 20)
                    Text(app.name)
                    Spacer()
                    Button {
                        store.settings.excludedApps.removeAll { $0 == app }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(app.name)")
                }
            }
            Menu("Add App") {
                let running = AppCatalog.runningApps(excluding: store.settings.excludedApps)
                ForEach(running) { app in
                    Button(app.name) { add(app) }
                }
                if !running.isEmpty { Divider() }
                Button("Choose…") {
                    if let app = AppCatalog.chooseApp() { add(app) }
                }
            }
            .fixedSize()
        } header: {
            Text("Excluded Apps")
        } footer: {
            Text("While one of these apps is in front, Ball Scrolling is off and the Trigger Button works as usual. Useful for games and 3D tools that need the button held.")
        }
    }

    private func add(_ app: ExcludedApp) {
        guard !store.settings.excludedApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        store.settings.excludedApps.append(app)
        store.settings.excludedApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // Snap in the binding instead of passing `step`, which would draw a
            // tick mark for every step.
            Slider(value: Binding(
                get: { value },
                set: { value = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }
            ), in: range)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
        }
    }
}

/// Finding apps to exclude.
enum AppCatalog {
    @MainActor
    static func runningApps(excluding excluded: [ExcludedApp]) -> [ExcludedApp] {
        let taken = Set(excluded.map(\.bundleID))
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> ExcludedApp? in
                guard let id = app.bundleIdentifier, id != own, !taken.contains(id) else { return nil }
                return ExcludedApp(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @MainActor
    static func chooseApp() -> ExcludedApp? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return ExcludedApp(bundleID: id, name: name)
    }

    @MainActor
    static func icon(forBundleID bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its "would like to control this computer" prompt.
    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LoginItem {
    /// Login items only work for a real app bundle, not a bare executable.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        isAvailable && SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message, or nil on success.
    static func set(enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
