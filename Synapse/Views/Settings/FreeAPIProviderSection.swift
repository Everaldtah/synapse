import SwiftUI
import SynapseKit

/// Cloud connection › Free API provider: which provider and model complex tasks (and Auto) use.
struct FreeAPIProviderSection: View {
    @Environment(AIService.self) private var ai
    @State private var testOutput: String?

    var body: some View {
        @Bindable var ai = ai
        let apis = APIProviderStore.shared
        Section {
            if apis.readyProviders.isEmpty {
                Text("No provider is set up yet. Most are free: NVIDIA NIM, Groq, Google Gemini, OpenRouter, Mistral and more; OVHcloud works with no key at all.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $ai.apiProviderID) {
                    Text("Choose…").tag("")
                    ForEach(apis.readyProviders) { Text($0.name).tag($0.id) }
                }
                .onChange(of: ai.apiProviderID) { _, id in
                    // Pick the provider's first model when the current one belongs to another provider.
                    if !apis.models(for: id).contains(where: { $0.id == ai.apiProviderModel }) {
                        ai.apiProviderModel = apis.favoriteModels(for: id).first?.id ?? ""
                    }
                }
                if !ai.apiProviderID.isEmpty {
                    Picker("Model", selection: $ai.apiProviderModel) {
                        ForEach(apis.models(for: ai.apiProviderID)) { m in
                            VStack(alignment: .leading) {
                                Text(m.shortName)
                                if !m.note.isEmpty { Text(m.note).font(.caption).foregroundStyle(.secondary) }
                            }
                            .tag(m.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
            NavigationLink { APIProvidersView() } label: { Label("API providers and keys", systemImage: "key") }
        } header: {
            Text("API provider")
        } footer: {
            Text("Requests go straight from this iPhone to the provider with your key (kept in the Keychain). Free tiers have rate limits; if one runs out, pick another provider. Every model you star also appears in the model pickers.")
        }
        if ai.isConfigured {
            Section {
                Button {
                    testOutput = "…"
                    Task { @MainActor in
                        do {
                            testOutput = try await ai.complete(AIRequest(system: "Reply in one short sentence.",
                                                                        messages: [AIMessage(role: .user, content: "Say hello and name the model you are.")]),
                                                              on: .cloud)
                        } catch {
                            testOutput = "⚠️ " + error.localizedDescription
                        }
                    }
                } label: { Label("Send a test message", systemImage: "paperplane") }
                if let testOutput { Text(testOutput).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }
}
