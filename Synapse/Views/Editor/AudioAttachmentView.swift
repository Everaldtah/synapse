import AVFoundation
import SwiftUI

/// A recording on a page: play/pause, scrub, and share.
struct AudioAttachmentView: View {
    let source: String
    let title: String
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var position: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var share = false
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if duration > 0 {
                    Slider(value: Binding(get: { position }, set: { seek($0) }), in: 0...max(duration, 0.1))
                        .controlSize(.mini)
                    Text("\(Self.time(position)) / \(Self.time(duration))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text(url == nil ? "File missing" : "Audio").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { share = true } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .disabled(url == nil)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor.separator)))
        .onAppear(perform: load)
        .onDisappear { player?.stop(); playing = false }
        .onReceive(tick) { _ in
            guard let player else { return }
            position = player.currentTime
            if playing && !player.isPlaying { playing = false }
        }
        .sheet(isPresented: $share) { if let url { ShareSheet(items: [url]) } }
    }

    private var url: URL? {
        guard let u = AssetStore.url(for: source), FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    private func load() {
        guard player == nil, let url else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
    }

    private func toggle() {
        load()
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            playing = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            playing = true
        }
    }

    private func seek(_ t: TimeInterval) {
        player?.currentTime = t
        position = t
    }

    static func time(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
