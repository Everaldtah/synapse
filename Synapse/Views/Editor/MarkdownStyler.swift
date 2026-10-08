import UIKit
import SynapseKit

extension NSAttributedString.Key {
    /// `[[link]]` target title.
    static let synapseLink = NSAttributedString.Key("synapse.link")
    /// Web link.
    static let synapseURL = NSAttributedString.Key("synapse.url")
    /// `#tag` name.
    static let synapseTag = NSAttributedString.Key("synapse.tag")
    /// `@date` mention.
    static let synapseDate = NSAttributedString.Key("synapse.date")
}

/// Live Markdown styling: the text stays editable Markdown, markers are dimmed, content is styled.
enum MarkdownStyler {
    struct Config {
        var type: BlockType
        var font: UIFont
        var color: UIColor
        var checked: Bool
        /// Does a `[[link]]` target exist?
        var resolves: (String) -> Bool
    }

    static func baseAttributes(_ config: Config) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = config.type.isHeading ? 1 : 3
        var attrs: [NSAttributedString.Key: Any] = [.font: config.font, .foregroundColor: config.color, .paragraphStyle: para]
        if config.type == .todo && config.checked {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = UIColor.secondaryLabel
        }
        if config.type == .quote { attrs[.font] = italic(config.font) }
        return attrs
    }

    static func style(_ storage: NSTextStorage, config: Config) {
        let text = storage.string
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes(config), range: full)
        if config.type != .code && config.type != .equation {
            for token in InlineMarkdown.tokens(in: text) {
                apply(token, storage, config)
            }
        }
        storage.endEditing()
    }

    private static func apply(_ token: InlineToken, _ storage: NSTextStorage, _ config: Config) {
        let c = token.contentRange
        guard c.location + c.length <= storage.length else { return }
        let accent = Palette.accentUI
        switch token.kind {
        case .bold:
            addTrait(.traitBold, storage, c)
        case .italic:
            addTrait(.traitItalic, storage, c)
        case .strike:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: c)
        case .underline:
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: c)
        case .highlight:
            storage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.32), range: c)
        case .code:
            storage.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: config.font.pointSize * 0.88, weight: .regular), range: token.range)
            storage.addAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, range: token.range)
            storage.addAttribute(.foregroundColor, value: UIColor.dynamic(light: 0xC7254E, dark: 0xFF7B8E), range: c)
        case .math:
            storage.addAttribute(.font, value: italic(UIFont.monospacedSystemFont(ofSize: config.font.pointSize * 0.92, weight: .regular)), range: c)
            storage.addAttribute(.foregroundColor, value: UIColor.systemPurple, range: c)
        case .link(let url):
            storage.addAttribute(.foregroundColor, value: accent, range: c)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: c)
            storage.addAttribute(.synapseURL, value: url, range: token.range)
        case .url(let url):
            storage.addAttribute(.foregroundColor, value: accent, range: c)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: c)
            storage.addAttribute(.synapseURL, value: url, range: token.range)
        case .wikiLink(let link):
            let exists = config.resolves(link.target)
            storage.addAttribute(.foregroundColor, value: exists ? accent : Palette.unresolvedUI, range: c)
            storage.addAttribute(.underlineStyle, value: (exists ? NSUnderlineStyle.single : NSUnderlineStyle.patternDash.union(.single)).rawValue, range: c)
            storage.addAttribute(.underlineColor, value: (exists ? accent : Palette.unresolvedUI).withAlphaComponent(0.45), range: c)
            storage.addAttribute(.synapseLink, value: link.target, range: token.range)
            if link.isEmbed { addTrait(.traitBold, storage, c) }
        case .tag(let tag):
            storage.addAttribute(.foregroundColor, value: accent, range: token.range)
            storage.addAttribute(.backgroundColor, value: accent.withAlphaComponent(0.12), range: token.range)
            storage.addAttribute(.synapseTag, value: tag, range: token.range)
        case .date(let d):
            storage.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: token.range)
            storage.addAttribute(.synapseDate, value: d, range: token.range)
        }
        for m in token.markerRanges where m.location + m.length <= storage.length {
            storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: m)
        }
    }

    private static func addTrait(_ trait: UIFontDescriptor.SymbolicTraits, _ storage: NSTextStorage, _ range: NSRange) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, r, _ in
            guard let f = value as? UIFont else { return }
            var traits = f.fontDescriptor.symbolicTraits
            traits.insert(trait)
            if let d = f.fontDescriptor.withSymbolicTraits(traits) {
                storage.addAttribute(.font, value: UIFont(descriptor: d, size: f.pointSize), range: r)
            }
        }
    }

    static func italic(_ f: UIFont) -> UIFont {
        var traits = f.fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)
        guard let d = f.fontDescriptor.withSymbolicTraits(traits) else { return f }
        return UIFont(descriptor: d, size: f.pointSize)
    }
}
