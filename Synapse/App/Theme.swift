import SwiftUI
import UIKit
import SynapseKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
}

enum Palette {
    static let accentUI = UIColor.dynamic(light: 0x6E56CF, dark: 0x9E8CFC)
    static let accent = Color(accentUI)
    static let unresolvedUI = UIColor.dynamic(light: 0x9A8FC4, dark: 0x7D74A3)
    static let paper = Color(UIColor.systemBackground)
    static let secondaryPaper = Color(UIColor.secondarySystemBackground)
}

extension Tint {
    var uiText: UIColor {
        switch self {
        case .none: return .label
        case .gray: return .dynamic(light: 0x787774, dark: 0x9B9B9B)
        case .brown: return .dynamic(light: 0x9F6B53, dark: 0xBA856F)
        case .orange: return .dynamic(light: 0xD9730D, dark: 0xC77D48)
        case .yellow: return .dynamic(light: 0xCB912F, dark: 0xCA9849)
        case .green: return .dynamic(light: 0x448361, dark: 0x529E72)
        case .blue: return .dynamic(light: 0x337EA9, dark: 0x379AD3)
        case .purple: return .dynamic(light: 0x9065B0, dark: 0x9D68D3)
        case .pink: return .dynamic(light: 0xC14C8A, dark: 0xD15796)
        case .red: return .dynamic(light: 0xD44C47, dark: 0xE65B58)
        }
    }

    var uiBackground: UIColor {
        switch self {
        case .none: return .clear
        case .gray: return .dynamic(light: 0xF1F1EF, dark: 0x2F2F2F)
        case .brown: return .dynamic(light: 0xF4EEEE, dark: 0x4A3228)
        case .orange: return .dynamic(light: 0xFBECDD, dark: 0x5C3B23)
        case .yellow: return .dynamic(light: 0xFBF3DB, dark: 0x564328)
        case .green: return .dynamic(light: 0xEDF3EC, dark: 0x243D30)
        case .blue: return .dynamic(light: 0xE7F3F8, dark: 0x143A4E)
        case .purple: return .dynamic(light: 0xF6F3F9, dark: 0x3C2D49)
        case .pink: return .dynamic(light: 0xFAF1F5, dark: 0x4E2C3C)
        case .red: return .dynamic(light: 0xFDEBEC, dark: 0x522E2A)
        }
    }

    /// Chip background for select options (a little stronger than block backgrounds).
    var uiChip: UIColor {
        switch self {
        case .none: return .dynamic(light: 0xE3E2E0, dark: 0x373737)
        case .gray: return .dynamic(light: 0xE3E2E0, dark: 0x5A5A5A)
        case .brown: return .dynamic(light: 0xEEE0DA, dark: 0x603B2C)
        case .orange: return .dynamic(light: 0xFADEC9, dark: 0x854C1D)
        case .yellow: return .dynamic(light: 0xFDECC8, dark: 0x89632A)
        case .green: return .dynamic(light: 0xDBEDDB, dark: 0x2B593F)
        case .blue: return .dynamic(light: 0xD3E5EF, dark: 0x28456C)
        case .purple: return .dynamic(light: 0xE8DEEE, dark: 0x492F64)
        case .pink: return .dynamic(light: 0xF5E0E9, dark: 0x69314C)
        case .red: return .dynamic(light: 0xFFE2DD, dark: 0x6E3630)
        }
    }

    var text: Color { Color(uiText) }
    var background: Color { Color(uiBackground) }
    var chip: Color { Color(uiChip) }
    /// A vivid colour for graph nodes and dots.
    var dot: Color { self == .none ? .secondary : Color(uiText) }
}

enum CoverStyle {
    static let gradients: [[UInt32]] = [
        [0x6E56CF, 0xE2A7F0], [0x1E3C72, 0x2A5298], [0xF6D365, 0xFDA085], [0x84FAB0, 0x8FD3F4],
        [0xA18CD1, 0xFBC2EB], [0x0F2027, 0x2C5364], [0xFF9A9E, 0xFAD0C4], [0x43E97B, 0x38F9D7],
    ]

    static func gradient(_ index: Int) -> LinearGradient {
        let g = gradients[((index % gradients.count) + gradients.count) % gradients.count]
        return LinearGradient(colors: g.map { Color(UIColor(hex: $0)) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Fonts for blocks, shared by the UIKit text views and SwiftUI prefixes so they line up.
enum BlockStyle {
    static func baseSize(small: Bool) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: small ? 15 : 17)
    }

    static func size(for type: BlockType, small: Bool) -> CGFloat {
        let base = baseSize(small: small)
        switch type {
        case .heading1: return base * 1.75
        case .heading2: return base * 1.42
        case .heading3: return base * 1.2
        case .code, .equation: return base * 0.88
        default: return base
        }
    }

    static func weight(for type: BlockType) -> UIFont.Weight {
        type.isHeading ? .bold : .regular
    }

    static func font(for type: BlockType, pageFont: PageFont, small: Bool) -> UIFont {
        let size = size(for: type, small: small)
        if type == .code || type == .equation { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        let base = UIFont.systemFont(ofSize: size, weight: weight(for: type))
        let design: UIFontDescriptor.SystemDesign
        switch pageFont {
        case .standard: return base
        case .serif: design = .serif
        case .mono: design = .monospaced
        }
        guard let d = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: d, size: size)
    }

    static let textInset: CGFloat = 4

    /// Height of the first line of a block, for aligning bullets and checkboxes.
    static func firstLineHeight(for type: BlockType, pageFont: PageFont, small: Bool) -> CGFloat {
        font(for: type, pageFont: pageFont, small: small).lineHeight + textInset * 2
    }

    static func swiftUIFont(_ pageFont: PageFont, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch pageFont {
        case .standard: return .system(size: size, weight: weight)
        case .serif: return .system(size: size, weight: weight, design: .serif)
        case .mono: return .system(size: size, weight: weight, design: .monospaced)
        }
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// The emoji (or a default symbol) for a page.
struct PageIconView: View {
    let page: Page
    var size: CGFloat = 17

    var body: some View {
        if !page.icon.isEmpty {
            Text(page.icon).font(.system(size: size))
        } else {
            Image(systemName: page.kind == .database ? "cylinder.split.1x2" : (page.dailyDate != nil ? "calendar" : "doc.text"))
                .font(.system(size: size * 0.85))
                .foregroundStyle(.secondary)
        }
    }
}

/// A rounded option chip ("In progress").
struct OptionChip: View {
    let name: String
    let color: Tint
    var dot = false

    var body: some View {
        HStack(spacing: 4) {
            if dot { Circle().fill(color.dot).frame(width: 7, height: 7) }
            Text(name).lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(color == .none ? Color.primary : color.text)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A page cover (gradient, colour or image) at a given height.
struct CoverView: View {
    let cover: Cover
    var height: CGFloat = 160

    var body: some View {
        Group {
            switch cover.kind {
            case .gradient:
                Rectangle().fill(CoverStyle.gradient(Int(cover.value) ?? 0))
            case .color:
                Rectangle().fill((Tint(rawValue: cover.value) ?? .blue).chip)
            case .image:
                StoredImage(source: cover.value, contentMode: .fill)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}
