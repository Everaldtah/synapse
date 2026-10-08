import SwiftUI
import UIKit

/// Images added to pages live in `Documents/Synapse/assets` and are referenced as `asset:<file name>`.
enum AssetStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synapse/assets", isDirectory: true)
    }

    static func url(for source: String) -> URL? {
        if source.hasPrefix("asset:") { return directory.appendingPathComponent(String(source.dropFirst(6))) }
        if source.hasPrefix("http://") || source.hasPrefix("https://") { return URL(string: source) }
        return nil
    }

    /// Save image data (downscaled to at most 2400 px, JPEG) and return its `asset:` reference.
    static func saveImage(_ data: Data) -> String? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var output = data
        var ext = "jpg"
        if let image = UIImage(data: data) {
            let maxSide: CGFloat = 2400
            let scale = min(1, maxSide / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpeg = resized.jpegData(compressionQuality: 0.85) { output = jpeg }
        } else {
            ext = "bin"
        }
        let name = UUID().uuidString + "." + ext
        do {
            try output.write(to: directory.appendingPathComponent(name), options: .atomic)
            return "asset:" + name
        } catch {
            return nil
        }
    }

    static func image(for source: String) -> UIImage? {
        guard source.hasPrefix("asset:"), let url = url(for: source) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

/// Shows an `asset:` image or a web image.
struct StoredImage: View {
    let source: String
    var contentMode: ContentMode = .fit

    var body: some View {
        if let ui = AssetStore.image(for: source) {
            Image(uiImage: ui).resizable().aspectRatio(contentMode: contentMode)
        } else if let url = AssetStore.url(for: source), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: contentMode)
                case .failure: placeholder(systemImage: "photo.badge.exclamationmark")
                default: placeholder(systemImage: "photo").overlay(ProgressView())
                }
            }
        } else {
            placeholder(systemImage: "photo")
        }
    }

    private func placeholder(systemImage: String) -> some View {
        Rectangle().fill(Color(UIColor.secondarySystemFill))
            .overlay(Image(systemName: systemImage).foregroundStyle(.secondary))
    }
}
