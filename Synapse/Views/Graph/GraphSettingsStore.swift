import Foundation
import Observation
import SynapseKit

/// The graph view's settings, shared by every graph screen and the AI agent. Persisted as JSON in UserDefaults.
@MainActor
@Observable
final class GraphSettingsStore {
    static let shared = GraphSettingsStore()

    private static let defaultsKey = "graph.viewSettings"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var stored: GraphViewSettings

    /// Every change is saved at once.
    var settings: GraphViewSettings {
        get {
            access(keyPath: \.settings)
            return stored
        }
        set {
            guard newValue != stored else { return }
            withMutation(keyPath: \.settings) { stored = newValue }
            save()
        }
    }

    /// Bumped to ask open graph screens to fit everything on screen.
    var fitRequest = 0
    /// Bumped to ask open graph screens to re-run the layout.
    var reheatRequest = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(GraphViewSettings.self, from: data) {
            stored = saved
        } else {
            stored = .default
        }
    }

    func requestFit() { fitRequest &+= 1 }

    func reheat() { reheatRequest &+= 1 }

    /// Back to the defaults (groups too), then re-run the layout.
    func reset() {
        settings = .default
        reheat()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
