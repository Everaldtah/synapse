import SwiftUI
import SynapseKit

@main
struct SynapseApp: App {
    @State private var store = WorkspaceStore()
    @State private var app = AppModel()
    @State private var ai = AIService()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = 0

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(app)
                .environment(ai)
                .tint(Palette.accent)
                .preferredColorScheme(appearance == 1 ? .light : (appearance == 2 ? .dark : nil))
                .onOpenURL { app.handle(url: $0, store: store) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.flush() }
        }
    }
}
