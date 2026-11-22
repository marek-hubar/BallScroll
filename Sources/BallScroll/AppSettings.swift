import BallScrollCore
import Foundation

struct ExcludedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String

    var id: String { bundleID }
}

/// Everything the user can configure, saved as one JSON value.
struct AppSettings: Codable, Equatable {
    var scroll = ScrollSettings()
    var trigger = TriggerButton.right
    var paused = false
    var excludedApps: [ExcludedApp] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? ScrollSettings()
        trigger = try c.decodeIfPresent(TriggerButton.self, forKey: .trigger) ?? .right
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        excludedApps = try c.decodeIfPresent([ExcludedApp].self, forKey: .excludedApps) ?? []
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "settings"

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?()
        }
    }

    /// True when no settings had been saved before this launch.
    let isFirstLaunch: Bool
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
            isFirstLaunch = false
        } else {
            settings = AppSettings()
            isFirstLaunch = true
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Live status shown in the menu and the settings window.
@MainActor
final class AppStatus: ObservableObject {
    enum Engine: Equatable {
        case needsPermission
        case running
        /// Permission is granted but the system still refused the event tap.
        case failed
    }

    @Published var engine: Engine = .needsPermission
    @Published var frontmostExcludedApp: String?
}
