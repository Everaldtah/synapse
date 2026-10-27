import SwiftUI
import UIKit
import SynapseKit

/// Obsidian-style graph settings: filters, colour groups, display and forces. Changes show live on the graph behind.
struct GraphSettingsSheet: View {
    /// Local graph vs whole workspace, when the graph has a focus page.
    var localMode: Binding<Bool>?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("graph.sheet.filters") private var filtersOpen = true
    @AppStorage("graph.sheet.groups") private var groupsOpen = false
    @AppStorage("graph.sheet.display") private var displayOpen = false
    @AppStorage("graph.sheet.forces") private var forcesOpen = false
    @State private var confirmReset = false
    @FocusState private var focusedGroup: UUID?

    /// Group colours, vivid first (new groups take the first one not in use).
    private static let palette: [Tint] = [.blue, .green, .orange, .purple, .pink, .red, .yellow, .brown, .gray]

    var body: some View {
        // Read here so outside changes (the AI, a reset) refresh every control.
        let _ = GraphSettingsStore.shared.settings
        @Bindable var store = GraphSettingsStore.shared
        NavigationStack {
            Form {
                Section {
                    DisclosureGroup(isExpanded: $filtersOpen) {
                        filters($store.settings)
                    } label: {
                        Text("Filters").font(.headline)
                    }
                }
                Section {
                    DisclosureGroup(isExpanded: $groupsOpen) {
                        groups($store.settings)
                    } label: {
                        Text("Groups").font(.headline)
                    }
                }
                Section {
                    DisclosureGroup(isExpanded: $displayOpen) {
                        display($store.settings)
                    } label: {
                        Text("Display").font(.headline)
                    }
                }
                Section {
                    DisclosureGroup(isExpanded: $forcesOpen) {
                        forces($store.settings)
                    } label: {
                        Text("Forces").font(.headline)
                    }
                }
                Section {
                    Button("Reset to defaults", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Graph settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Reset every graph setting, including groups?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { GraphSettingsStore.shared.reset() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.scrolls)
    }

    // MARK: Sections

    @ViewBuilder private func filters(_ s: Binding<GraphViewSettings>) -> some View {
        if let localMode {
            Picker("Graph", selection: localMode) {
                Text("Local graph").tag(true)
                Text("Whole workspace").tag(false)
            }
            .pickerStyle(.segmented)
            if localMode.wrappedValue {
                let depth = s.wrappedValue.depth
                Stepper(value: s.depth, in: GraphViewSettings.depthRange) {
                    Text("Depth: \(depth) link\(depth == 1 ? "" : "s") away")
                }
            }
        }
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search nodes", text: s.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        Toggle("Tags", isOn: s.showTags)
        Toggle("Unresolved links", isOn: s.showUnresolved)
        Toggle("Orphans", isOn: s.showOrphans)
        Toggle("Database rows", isOn: s.showRows)
        Toggle("Daily notes", isOn: s.showDaily)
        Toggle("Relations", isOn: s.showRelations)
        Toggle("Page hierarchy", isOn: s.showHierarchy)
    }

    @ViewBuilder private func groups(_ s: Binding<GraphViewSettings>) -> some View {
        ForEach(s.groups) { group in
            groupRow(group, in: s)
        }
        .onDelete { s.wrappedValue.groups.remove(atOffsets: $0) }
        Button {
            addGroup(s)
        } label: {
            Label("New group", systemImage: "plus.circle")
        }
        if s.wrappedValue.colorMode != .groups && !s.wrappedValue.groups.isEmpty {
            Button {
                s.wrappedValue.colorMode = .groups
            } label: {
                Label("Colour the graph by groups", systemImage: "paintpalette")
            }
        }
        Text("A node takes the colour of the first group it matches. Queries: tag:idea or #idea · path:Projects (a page and everything under it) · kind:database, row, daily or page · title:meeting · line:words (in the page text) · plain words (in the title).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func display(_ s: Binding<GraphViewSettings>) -> some View {
        Picker("Colour by", selection: s.colorMode) {
            ForEach(GraphColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle("Arrows", isOn: s.showArrows)
        slider("Text fade threshold", s.labelZoom, GraphViewSettings.labelZoomRange, digits: 1)
        slider("Node size", s.nodeSize, GraphViewSettings.nodeSizeRange, digits: 1)
        slider("Link thickness", s.linkThickness, GraphViewSettings.linkThicknessRange, digits: 1)
        Text("Every node shows its name once you zoom in past the text fade threshold.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func forces(_ s: Binding<GraphViewSettings>) -> some View {
        slider("Center force", s.centerForce, GraphViewSettings.centerForceRange, digits: 3)
        slider("Repel force", s.repelForce, GraphViewSettings.repelForceRange, digits: 0)
        slider("Link force", s.linkForce, GraphViewSettings.linkForceRange, digits: 2)
        slider("Link distance", s.linkDistance, GraphViewSettings.linkDistanceRange, digits: 0)
        Button {
            GraphSettingsStore.shared.reheat()
        } label: {
            Label("Re-run layout", systemImage: "arrow.triangle.2.circlepath")
        }
    }

    // MARK: Rows

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, digits: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                Text(value.wrappedValue, format: .number.precision(.fractionLength(digits)))
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func groupRow(_ group: Binding<GraphGroup>, in s: Binding<GraphViewSettings>) -> some View {
        let id = group.wrappedValue.id
        let color = group.wrappedValue.color
        return HStack(spacing: 12) {
            Menu {
                Picker("Colour", selection: group.color) {
                    ForEach(Self.palette, id: \.self) { tint in
                        Label {
                            Text(tint.title)
                        } icon: {
                            Image(uiImage: Self.swatch(tint))
                        }
                        .tag(tint)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    s.wrappedValue.groups.removeAll { $0.id == id }
                } label: {
                    Label("Delete group", systemImage: "trash")
                }
            } label: {
                Circle()
                    .fill(color.dot)
                    .frame(width: 22, height: 22)
                    .overlay { Circle().strokeBorder(Color.primary.opacity(0.15)) }
            }
            .accessibilityLabel("Group colour: \(color.title)")
            TextField("tag:idea", text: group.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedGroup, equals: id)
        }
    }

    private func addGroup(_ s: Binding<GraphViewSettings>) {
        let used = Set(s.wrappedValue.groups.map(\.color))
        let color = Self.palette.first { !used.contains($0) } ?? Self.palette[s.wrappedValue.groups.count % Self.palette.count]
        let group = GraphGroup(query: "", color: color)
        s.wrappedValue.groups.append(group)
        s.wrappedValue.colorMode = .groups
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            focusedGroup = group.id
        }
    }

    /// A coloured dot for menus (menus draw template images in one colour, so the colour is baked in).
    private static func swatch(_ tint: Tint) -> UIImage {
        (UIImage(systemName: "circle.fill") ?? UIImage()).withTintColor(tint.uiText, renderingMode: .alwaysOriginal)
    }
}
