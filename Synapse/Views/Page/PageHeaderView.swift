import SwiftUI
import PhotosUI
import SynapseKit

/// Cover, icon, title and (for database rows) the property list.
struct PageHeaderView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let pageID: UUID
    var onReturn: () -> Void = {}

    @State private var title = ""
    @State private var titleAtStart = ""
    @FocusState private var titleFocused: Bool
    @State private var showEmoji = false
    @State private var coverPick: PhotosPickerItem?
    @State private var showCoverPhotos = false

    var body: some View {
        if let page = store.page(pageID) {
            VStack(alignment: .leading, spacing: 0) {
                if let cover = page.cover {
                    CoverView(cover: cover, height: 170)
                        .overlay(alignment: .bottomTrailing) {
                            if !page.locked { coverMenu(page).padding(10) }
                        }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if !page.icon.isEmpty {
                        Button { showEmoji = true } label: { Text(page.icon).font(.system(size: 56)) }
                            .buttonStyle(.plain)
                            .disabled(page.locked)
                            .padding(.top, page.cover == nil ? 12 : -34)
                    }
                    if !page.locked && (page.icon.isEmpty || page.cover == nil) {
                        HStack(spacing: 14) {
                            if page.icon.isEmpty {
                                Button { showEmoji = true } label: { Label("Add icon", systemImage: "face.smiling") }
                            }
                            if page.cover == nil {
                                Button { store.update(pageID, touch: false) { $0.cover = Cover.randomGradient() } } label: {
                                    Label("Add cover", systemImage: "photo")
                                }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        .padding(.top, page.icon.isEmpty && page.cover == nil ? 12 : 0)
                    }
                    if let parent = page.parentID, page.kind == .row, let db = store.page(parent) {
                        Button { app.open(db.id) } label: {
                            HStack(spacing: 4) {
                                PageIconView(page: db, size: 12)
                                Text(db.displayTitle)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("Untitled", text: $title, axis: .vertical)
                        .font(BlockStyle.swiftUIFont(page.font, size: page.smallText ? 28 : 32, weight: .bold))
                        .focused($titleFocused)
                        .disabled(page.locked)
                        .submitLabel(.next)
                        .onSubmit { finishTitle(); onReturn() }
                        .onChange(of: title) { _, newValue in
                            // Return in a vertical text field arrives as a newline.
                            if newValue.contains("\n") {
                                title = newValue.replacingOccurrences(of: "\n", with: "")
                                titleFocused = false
                                finishTitle()
                                onReturn()
                                return
                            }
                            if newValue != store.page(pageID)?.title { store.update(pageID) { $0.title = newValue } }
                        }
                        .onChange(of: titleFocused) { _, focused in
                            if focused { titleAtStart = page.title } else { finishTitle() }
                        }
                    if page.dailyDate != nil {
                        Label("Daily note", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                    }
                    if !page.aliases.isEmpty {
                        Text("Also: " + page.aliases.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if page.locked {
                        Label("Locked", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    if page.kind == .row, let dbID = page.parentID {
                        RowPropertiesView(rowID: pageID, databaseID: dbID)
                            .padding(.top, 6)
                        Divider().padding(.top, 6)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .onAppear {
                title = page.title
                if page.title.isEmpty && page.blocks.count <= 1 && page.blocks.first?.text.isEmpty != false && page.kind != .row {
                    titleFocused = true
                }
            }
            .onChange(of: page.title) { _, t in if !titleFocused && t != title { title = t } }
            .sheet(isPresented: $showEmoji) {
                EmojiPicker(current: page.icon) { e in store.update(pageID, touch: false) { $0.icon = e } }
            }
            .photosPicker(isPresented: $showCoverPhotos, selection: $coverPick, matching: .images)
            .onChange(of: coverPick) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let ref = AssetStore.saveImage(data) {
                        store.update(pageID, touch: false) { $0.cover = Cover(kind: .image, value: ref) }
                    }
                    coverPick = nil
                }
            }
        }
    }

    private func finishTitle() {
        let old = titleAtStart
        let new = title.trimmingCharacters(in: .whitespaces)
        guard old != new else { return }
        // Rewrite [[links]] that pointed at the old title.
        store.update(pageID) { $0.title = old }
        store.rename(pageID, to: new)
        titleAtStart = new
    }

    private func coverMenu(_ page: Page) -> some View {
        Menu {
            Section("Gradients") {
                ForEach(0..<Cover.gradientCount, id: \.self) { i in
                    Button("Gradient \(i + 1)") { store.update(pageID, touch: false) { $0.cover = Cover(kind: .gradient, value: String(i)) } }
                }
            }
            Section("Colours") {
                ForEach(Tint.allCases.filter { $0 != .none }, id: \.self) { t in
                    Button(t.title) { store.update(pageID, touch: false) { $0.cover = Cover(kind: .color, value: t.rawValue) } }
                }
            }
            Button { showCoverPhotos = true } label: { Label("Photo…", systemImage: "photo") }
            Button(role: .destructive) { store.update(pageID, touch: false) { $0.cover = nil } } label: { Label("Remove cover", systemImage: "trash") }
        } label: {
            Text("Change cover")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Emoji grid for page and callout icons.
struct EmojiPicker: View {
    @Environment(\.dismiss) private var dismiss
    let current: String
    let onPick: (String) -> Void
    @State private var custom = ""

    static let groups: [(String, String)] = [
        ("Popular", "📝📄📚🧠💡📌✅🚀🎯🔥⭐️❤️🗓️📅📊📈🧪🛠️⚙️🔑🔒🌱🌍🏠💼🎓🎨🎵📷✈️🍀"),
        ("Smileys", "😀😃😄😁😆🥹😅😂🤣🥲😊😇🙂🙃😉😌😍🥰😘😋😛🤓😎🥸🤩🥳😏🤔🫡🤗🤫😴🤯🥶😱"),
        ("People", "👋🤚✋🖖👌🤌✌️🤞🫰🤟🤘👍👎👏🙌🫶👐🤝🙏✍️💪🧠👀👤👥🧑‍💻👩‍🔬👨‍🍳🧑‍🎨🧑‍🚀🕵️"),
        ("Nature", "🌱🌿🍀🌳🌲🌴🌵🌸🌼🌻🌞🌙⭐️🌈☁️⚡️❄️🔥💧🌊🐶🐱🦊🐻🐼🐨🦁🐯🦉🐝🦋🐢🐬🐙"),
        ("Objects", "💻⌨️🖥️📱⌚️📷🎥📺🔋💡🔦📦📮✏️🖊️📎📐📏✂️🗂️📁📂🗃️🗄️🧾💳💰🔧🔨🧰🧲🧪🔬🔭📡"),
        ("Symbols", "❤️🧡💛💚💙💜🖤🤍✅☑️✔️❌⭕️❗️❓⚠️🚫♻️🔆🔅〽️🔱⚜️🔰✳️❇️💠🔷🔶🔺🔻💬💭🗯️♾️"),
        ("Travel", "🚗🚕🚙🚌🏎️🚓🚑🚒✈️🚀🛸🚁⛵️🚢🗺️🗽🗼🏰🏯🏟️🎡🎢⛰️🏔️🏕️🏖️🏝️🏜️🌋🗻"),
        ("Food", "🍏🍎🍐🍊🍋🍌🍉🍇🍓🫐🍒🍑🥭🍍🥥🥝🍅🥑🥦🌽🥕🥐🥯🍞🧀🍳🥞🍔🍟🍕🌮🍣🍜🍰☕️🍵"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("Type or paste any emoji", text: $custom).textFieldStyle(.roundedBorder)
                        Button("Use") {
                            if let c = custom.first { onPick(String(c)); dismiss() }
                        }
                        .disabled(custom.isEmpty)
                    }
                    ForEach(Self.groups, id: \.0) { group in
                        Text(group.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                            ForEach(Array(group.1).map(String.init), id: \.self) { e in
                                Button {
                                    onPick(e)
                                    dismiss()
                                } label: {
                                    Text(e).font(.system(size: 30))
                                        .frame(width: 40, height: 40)
                                        .background(e == current ? Palette.accent.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove", role: .destructive) {
                        onPick("")
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
