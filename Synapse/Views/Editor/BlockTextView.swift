import SwiftUI
import UIKit
import SynapseKit

/// The text view inside a block: live Markdown styling, Return/Backspace block behaviour, Markdown shortcuts,
/// "/" menu, "[[" link picker, tappable links, and the formatting bar above the keyboard.
final class SynapseTextView: UITextView {
    var onBackspaceAtStart: (() -> Void)?
    var onTap: ((CGPoint) -> Bool)?
    var wantsFocus = false
    var pendingSelection: NSRange?
    var canEdit = true
    let placeholderLabel = UILabel()
    private weak var linkTap: UITapGestureRecognizer?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        isScrollEnabled = false
        isEditable = false
        isSelectable = true
        textContainerInset = UIEdgeInsets(top: BlockStyle.textInset, left: 0, bottom: BlockStyle.textInset, right: 0)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        adjustsFontForContentSizeCategory = false
        autocorrectionType = .default
        smartDashesType = .no
        smartQuotesType = .default
        dataDetectorTypes = []
        keyboardDismissMode = .none
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.numberOfLines = 1
        addSubview(placeholderLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = true
        addGestureRecognizer(tap)
        linkTap = tap
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard !isFirstResponder else { return }
        let point = g.location(in: self)
        if onTap?(point) == true { return }
        guard canEdit else { return }
        isEditable = true
        becomeFirstResponder()
        if let pos = closestPosition(to: point) {
            let offset = self.offset(from: beginningOfDocument, to: pos)
            selectedRange = NSRange(location: offset, length: 0)
        }
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // Our tap only works while not editing; while editing, UIKit places the caret.
        if g === linkTap { return !isFirstResponder }
        return super.gestureRecognizerShouldBegin(g)
    }

    override func deleteBackward() {
        if selectedRange.location == 0 && selectedRange.length == 0 {
            onBackspaceAtStart?()
            return
        }
        super.deleteBackward()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && wantsFocus {
            DispatchQueue.main.async { [weak self] in self?.takeFocus() }
        }
    }

    func takeFocus() {
        guard window != nil, canEdit else { return }
        if !isFirstResponder {
            isEditable = true
            becomeFirstResponder()
        }
        if let sel = pendingSelection {
            let len = (text as NSString).length
            let loc = min(max(0, sel.location), len)
            selectedRange = NSRange(location: loc, length: max(0, min(sel.length, len - loc)))
            pendingSelection = nil
        }
        wantsFocus = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(x: textContainerInset.left + textContainer.lineFragmentPadding,
                                        y: textContainerInset.top,
                                        width: bounds.width - textContainerInset.left - textContainerInset.right,
                                        height: (placeholderLabel.font ?? .preferredFont(forTextStyle: .body)).lineHeight)
    }
}

/// A tappable item in the formatting bar.
struct KeyboardBarItem {
    var symbol: String
    var label: String
    var action: (() -> Void)?
    var menu: UIMenu?
}

final class KeyboardBar: UIInputView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    init(items: [KeyboardBarItem]) {
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 0
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        for item in items {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11)
            config.baseForegroundColor = .label
            let button = UIButton(configuration: config)
            if let action = item.action {
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            }
            if let menu = item.menu {
                button.menu = menu
                button.showsMenuAsPrimaryAction = true
            }
            button.accessibilityLabel = item.label
            stack.addArrangedSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }
}

/// SwiftUI wrapper for one block's text.
struct BlockTextView: UIViewRepresentable {
    let item: BlockItem
    let model: PageEditorModel
    let pageFont: PageFont
    let smallText: Bool
    let resolves: (String) -> Bool
    let onOpenLink: (String) -> Void
    let onOpenURL: (URL) -> Void
    let onOpenTag: (String) -> Void
    let onOpenDate: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SynapseTextView {
        let tv = SynapseTextView(frame: .zero, textContainer: nil)
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        tv.onBackspaceAtStart = { [weak coordinator = context.coordinator] in coordinator?.backspaceAtStart() }
        tv.onTap = { [weak coordinator = context.coordinator] point in coordinator?.tap(at: point) ?? false }
        tv.text = item.text
        context.coordinator.lastStyledText = nil
        context.coordinator.restyle()
        if model.focusedID == item.id {
            tv.wantsFocus = true
            if let req = model.focusRequest, req.blockID == item.id {
                tv.pendingSelection = NSRange(location: req.location, length: req.length)
                context.coordinator.handledRequest = req.token
            } else {
                tv.pendingSelection = model.selection
            }
        }
        return tv
    }

    func updateUIView(_ tv: SynapseTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        tv.canEdit = !model.readOnly
        if tv.text != item.text {
            let sel = tv.selectedRange
            tv.text = item.text
            let len = (item.text as NSString).length
            tv.selectedRange = NSRange(location: min(sel.location, len), length: 0)
            c.lastStyledText = nil
        }
        c.restyle()
        c.updatePlaceholder()
        if let req = model.focusRequest, req.blockID == item.id, req.token != c.handledRequest {
            c.handledRequest = req.token
            tv.pendingSelection = NSRange(location: req.location, length: req.length)
            tv.wantsFocus = true
            if tv.window != nil {
                DispatchQueue.main.async { tv.takeFocus() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SynapseTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        guard width > 0, width.isFinite else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(size.height, BlockStyle.firstLineHeight(for: item.block.type, pageFont: pageFont, small: smallText)))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BlockTextView
        weak var textView: SynapseTextView?
        var handledRequest: UUID?
        var lastStyledText: String?
        var lastStyleKey = ""

        init(_ parent: BlockTextView) { self.parent = parent }

        private var model: PageEditorModel { parent.model }
        private var item: BlockItem { parent.item }
        private var type: BlockType { item.block.type }

        // MARK: Styling

        func restyle(force: Bool = false) {
            guard let tv = textView else { return }
            if tv.markedTextRange != nil { return }
            let b = item.block
            let key = "\(b.type.rawValue)|\(b.checked)|\(b.textColor.rawValue)|\(parent.pageFont.rawValue)|\(parent.smallText)"
            if !force && lastStyledText == tv.text && lastStyleKey == key { return }
            let font = BlockStyle.font(for: b.type, pageFont: parent.pageFont, small: parent.smallText)
            let color: UIColor = b.textColor == .none ? .label : b.textColor.uiText
            let config = MarkdownStyler.Config(type: b.type, font: font, color: color, checked: b.checked, resolves: parent.resolves)
            let sel = tv.selectedRange
            MarkdownStyler.style(tv.textStorage, config: config)
            tv.selectedRange = sel
            tv.typingAttributes = MarkdownStyler.baseAttributes(config)
            tv.placeholderLabel.font = font
            tv.autocapitalizationType = b.type == .code ? .none : .sentences
            tv.autocorrectionType = b.type == .code || b.type == .equation ? .no : .default
            tv.spellCheckingType = b.type == .code || b.type == .equation ? .no : .default
            tv.smartQuotesType = b.type == .code || b.type == .equation ? .no : .default
            lastStyledText = tv.text
            lastStyleKey = key
            updatePlaceholder()
        }

        func updatePlaceholder() {
            guard let tv = textView else { return }
            let empty = tv.text.isEmpty
            let focused = tv.isFirstResponder
            var placeholder = ""
            switch type {
            case .heading1: placeholder = "Heading 1"
            case .heading2: placeholder = "Heading 2"
            case .heading3: placeholder = "Heading 3"
            case .todo: placeholder = "To-do"
            case .bulleted, .numbered: placeholder = "List"
            case .toggle: placeholder = "Toggle"
            case .quote: placeholder = "Empty quote"
            case .callout: placeholder = "Type something…"
            case .code: placeholder = "Code"
            case .equation: placeholder = "LaTeX, e.g. E = mc^2"
            default: placeholder = focused ? "Type '/' for commands, '[[' to link" : ""
            }
            if model.readOnly { placeholder = "" }
            tv.placeholderLabel.text = placeholder
            tv.placeholderLabel.isHidden = !empty || placeholder.isEmpty
        }

        // MARK: Taps on links

        func tap(at point: CGPoint) -> Bool {
            guard let tv = textView, tv.textStorage.length > 0, let pos = tv.closestPosition(to: point) else { return false }
            var offset = tv.offset(from: tv.beginningOfDocument, to: pos)
            // closestPosition can land just after the tapped character.
            if point.x < tv.caretRect(for: pos).minX, offset > 0 { offset -= 1 }
            offset = min(max(0, offset), tv.textStorage.length - 1)
            // Only count taps on the character itself, not beside or below the text.
            if let start = tv.position(from: tv.beginningOfDocument, offset: offset),
               let end = tv.position(from: start, offset: 1),
               let range = tv.textRange(from: start, to: end) {
                let rect = tv.firstRect(for: range).insetBy(dx: -6, dy: -6)
                if !rect.contains(point) { return false }
            }
            let attrs = tv.textStorage.attributes(at: offset, effectiveRange: nil)
            if let target = attrs[.synapseLink] as? String {
                parent.onOpenLink(target)
                return true
            }
            if let url = attrs[.synapseURL] as? String, let u = URL(string: url) {
                parent.onOpenURL(u)
                return true
            }
            if let tag = attrs[.synapseTag] as? String {
                parent.onOpenTag(tag)
                return true
            }
            if let d = attrs[.synapseDate] as? String {
                parent.onOpenDate(d)
                return true
            }
            return false
        }

        // MARK: Delegate

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            if model.readOnly { return false }
            if textView.inputAccessoryView == nil { textView.inputAccessoryView = makeBar() }
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if model.focusedID != item.id { model.focusedID = item.id }
            updatePlaceholder()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if model.focusedID == item.id { model.focusedID = nil }
            if model.slash?.blockID == item.id { model.slash = nil }
            if model.link?.blockID == item.id { model.link = nil }
            textView.isEditable = false
            updatePlaceholder()
            model.scheduleCommit()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.isFirstResponder { model.selection = textView.selectedRange }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let ns = textView.text as NSString
            // Return → new block (code and equations keep newlines).
            if text == "\n" && type != .code && type != .equation {
                if model.slash != nil, let first = SlashMenu.matches(model.slash?.query ?? "").first {
                    commitText(textView.text)
                    model.apply(first)
                    return false
                }
                if let l = model.link, l.blockID == item.id {
                    let q = l.query.trimmingCharacters(in: .whitespaces)
                    if !q.isEmpty { model.applyLink(title: Search.quickSwitch(q, in: model.store?.workspace ?? Workspace(), limit: 1).first?.displayTitle ?? q) }
                    return false
                }
                commitText(textView.text)
                model.split(item.id, at: range.location)
                return false
            }
            // Markdown shortcuts at the start of a plain paragraph.
            if text == " " && type == .paragraph && range.length == 0 {
                let prefix = ns.substring(to: range.location)
                if let (newType, checked) = shortcut(prefix) {
                    let rest = ns.substring(from: range.location)
                    model.update(item.id) {
                        $0.type = newType
                        $0.checked = checked
                        $0.text = rest
                        if newType == .callout && $0.icon.isEmpty { $0.icon = "💡" }
                    }
                    textView.text = rest
                    textView.selectedRange = NSRange(location: 0, length: 0)
                    lastStyledText = nil
                    restyle(force: true)
                    return false
                }
            }
            if type == .paragraph && range.location == 2 && range.length == 0 {
                if text == "-" && ns.substring(to: 2) == "--" && ns.length == 2 {
                    model.update(item.id) { $0.type = .divider; $0.text = "" }
                    model.insert(Block(indent: item.block.indent), after: item.id)
                    return false
                }
                if text == "`" && ns.substring(to: 2) == "``" && ns.length == 2 {
                    model.update(item.id) { $0.type = .code; $0.text = "" }
                    textView.text = ""
                    return false
                }
            }
            // "[[" → link picker with auto-closed brackets.
            if text == "[" && range.location > 0 && range.length == 0 && type != .code && type != .equation,
               ns.substring(with: NSRange(location: range.location - 1, length: 1)) == "[" {
                let newText = ns.replacingCharacters(in: range, with: "[]]")
                textView.text = newText
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                commitText(newText)
                model.link = LinkState(blockID: item.id, start: range.location + 1, query: "")
                lastStyledText = nil
                restyle()
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            commitText(textView.text)
            if textView.markedTextRange == nil { restyle() }
            updateSlashAndLink(textView)
            updatePlaceholder()
            // Let SwiftUI re-measure the row.
            textView.invalidateIntrinsicContentSize()
        }

        private func commitText(_ text: String) {
            model.setText(item.id, text)
        }

        private func shortcut(_ prefix: String) -> (BlockType, Bool)? {
            switch prefix {
            case "#": return (.heading1, false)
            case "##": return (.heading2, false)
            case "###": return (.heading3, false)
            case "-", "*", "+", "•": return (.bulleted, false)
            case "[]", "[ ]": return (.todo, false)
            case "[x]", "[X]": return (.todo, true)
            case ">": return (.toggle, false)
            case "\"", "“", "|": return (.quote, false)
            case "!": return (.callout, false)
            case "$$": return (.equation, false)
            default:
                if prefix.count <= 4, prefix.hasSuffix("."), Int(prefix.dropLast()) != nil { return (.numbered, false) }
                return nil
            }
        }

        private func updateSlashAndLink(_ tv: UITextView) {
            let ns = tv.text as NSString
            let caret = tv.selectedRange.location
            // Open the slash menu when "/" is typed at the start or after a space.
            if model.slash == nil, caret > 0, caret <= ns.length, ns.substring(with: NSRange(location: caret - 1, length: 1)) == "/",
               type != .code, type != .equation {
                let before = caret >= 2 ? ns.substring(with: NSRange(location: caret - 2, length: 1)) : " "
                if before == " " || before == "\n" || caret == 1 {
                    model.slash = SlashState(blockID: item.id, start: caret - 1, query: "")
                    return
                }
            }
            if let s = model.slash, s.blockID == item.id {
                guard s.start < ns.length, caret > s.start, ns.substring(with: NSRange(location: s.start, length: 1)) == "/" else {
                    model.slash = nil
                    return
                }
                let q = ns.substring(with: NSRange(location: s.start + 1, length: caret - s.start - 1))
                if q.contains("\n") || q.count > 24 || q.hasSuffix("  ") || (SlashMenu.matches(q).isEmpty && q.count > 3) {
                    model.slash = nil
                } else if q != s.query {
                    model.slash?.query = q
                }
            }
            if let l = model.link, l.blockID == item.id {
                guard caret >= l.start, l.start >= 2, l.start <= ns.length,
                      ns.substring(with: NSRange(location: l.start - 2, length: 2)) == "[[" else {
                    model.link = nil
                    return
                }
                let rest = ns.substring(from: l.start) as NSString
                let close = rest.range(of: "]]")
                let end = close.location == NSNotFound ? rest.length : close.location
                if caret > l.start + end { model.link = nil; return }
                let q = rest.substring(to: end)
                if q.contains("\n") || q.count > 80 { model.link = nil; return }
                if q != l.query { model.link?.query = q }
            }
        }

        func backspaceAtStart() {
            guard let tv = textView else { return }
            commitText(tv.text)
            model.backspaceAtStart(item.id)
        }

        // MARK: Formatting bar

        private func wrap(_ open: String, _ close: String) {
            guard let tv = textView else { return }
            let range = tv.selectedRange
            let ns = tv.text as NSString
            if range.length == 0 {
                let newText = ns.replacingCharacters(in: range, with: open + close)
                tv.text = newText
                tv.selectedRange = NSRange(location: range.location + (open as NSString).length, length: 0)
                commitText(newText)
            } else {
                let (t, r) = InlineMarkdown.toggleWrap(tv.text, range: range, open: open, close: close)
                tv.text = t
                tv.selectedRange = r
                commitText(t)
            }
            lastStyledText = nil
            restyle()
            Haptics.tap()
        }

        private func insertAtCaret(_ s: String) {
            guard let tv = textView else { return }
            tv.insertText(s)
        }

        private func startLink() {
            guard let tv = textView else { return }
            let range = tv.selectedRange
            if range.length > 0 {
                wrap("[[", "]]")
                return
            }
            let ns = tv.text as NSString
            let newText = ns.replacingCharacters(in: range, with: "[[]]")
            tv.text = newText
            tv.selectedRange = NSRange(location: range.location + 2, length: 0)
            commitText(newText)
            model.link = LinkState(blockID: item.id, start: range.location + 2, query: "")
            lastStyledText = nil
            restyle()
        }

        private func askAI() {
            guard let tv = textView else { return }
            let range = tv.selectedRange
            let ns = tv.text as NSString
            if range.length > 0 {
                model.aiRequest = EditorAIRequest(blockIDs: [item.id], selectedText: ns.substring(with: range), range: range)
            } else {
                model.aiRequest = EditorAIRequest(blockIDs: [item.id], selectedText: tv.text, range: nil)
            }
            tv.resignFirstResponder()
        }

        private func turnIntoMenu() -> UIMenu {
            let types: [BlockType] = [.paragraph, .heading1, .heading2, .heading3, .bulleted, .numbered, .todo, .toggle, .quote, .callout, .code, .equation]
            let actions = types.map { t in
                UIAction(title: t.title, image: UIImage(systemName: t.symbol), state: t == item.block.type ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.commitText(self.textView?.text ?? "")
                    self.model.turnInto(self.item.id, t)
                }
            }
            return UIMenu(title: "Turn into", children: actions)
        }

        /// Menus rebuilt every time they open, so the checkmarks match the block.
        private func deferred(_ make: @escaping () -> UIMenu) -> UIMenu {
            UIMenu(children: [UIDeferredMenuElement.uncached { completion in
                MainActor.assumeIsolated { completion(make().children) }
            }])
        }

        private func colorMenu() -> UIMenu {
            let text = Tint.allCases.map { t in
                UIAction(title: t.title, image: UIImage(systemName: "textformat")?.withTintColor(t.uiText, renderingMode: .alwaysOriginal),
                         state: item.block.textColor == t ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.model.update(self.item.id) { $0.textColor = t }
                }
            }
            let bg = Tint.allCases.map { t in
                UIAction(title: t == .none ? "No background" : "\(t.title) background",
                         image: UIImage(systemName: "square.fill")?.withTintColor(t == .none ? .systemGray4 : t.uiChip, renderingMode: .alwaysOriginal),
                         state: item.block.background == t ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.model.update(self.item.id) { $0.background = t }
                }
            }
            return UIMenu(title: "Colour", children: [UIMenu(title: "Text", options: .displayInline, children: text),
                                                      UIMenu(title: "Background", options: .displayInline, children: bg)])
        }

        private func makeBar() -> KeyboardBar {
            let id = item.id
            let items: [KeyboardBarItem] = [
                KeyboardBarItem(symbol: "plus", label: "Add block") { [weak self] in
                    guard let self else { return }
                    self.commitText(self.textView?.text ?? "")
                    let new = self.model.insert(Block(text: "/", indent: self.item.block.indent), after: id)
                    self.model.focus(new, at: 1)
                    self.model.slash = SlashState(blockID: new, start: 0, query: "")
                },
                KeyboardBarItem(symbol: "textformat", label: "Turn into", action: nil, menu: deferred { [weak self] in self?.turnIntoMenu() ?? UIMenu() }),
                KeyboardBarItem(symbol: "bold", label: "Bold") { [weak self] in self?.wrap("**", "**") },
                KeyboardBarItem(symbol: "italic", label: "Italic") { [weak self] in self?.wrap("*", "*") },
                KeyboardBarItem(symbol: "underline", label: "Underline") { [weak self] in self?.wrap("<u>", "</u>") },
                KeyboardBarItem(symbol: "strikethrough", label: "Strikethrough") { [weak self] in self?.wrap("~~", "~~") },
                KeyboardBarItem(symbol: "chevron.left.forwardslash.chevron.right", label: "Inline code") { [weak self] in self?.wrap("`", "`") },
                KeyboardBarItem(symbol: "highlighter", label: "Highlight") { [weak self] in self?.wrap("==", "==") },
                KeyboardBarItem(symbol: "link", label: "Link to page") { [weak self] in self?.startLink() },
                KeyboardBarItem(symbol: "number", label: "Tag") { [weak self] in self?.insertAtCaret("#") },
                KeyboardBarItem(symbol: "calendar", label: "Mention today") { [weak self] in
                    self?.insertAtCaret("@" + DateText.iso(Date()) + " ")
                },
                KeyboardBarItem(symbol: "paintpalette", label: "Colour", action: nil, menu: deferred { [weak self] in self?.colorMenu() ?? UIMenu() }),
                KeyboardBarItem(symbol: "checkmark.square", label: "To-do") { [weak self] in
                    guard let self else { return }
                    if self.item.block.type == .todo { self.model.toggleChecked(id) } else { self.model.turnInto(id, .todo) }
                },
                KeyboardBarItem(symbol: "increase.indent", label: "Indent") { [weak self] in self?.model.indent(id) },
                KeyboardBarItem(symbol: "decrease.indent", label: "Outdent") { [weak self] in self?.model.outdent(id) },
                KeyboardBarItem(symbol: "arrow.up", label: "Move up") { [weak self] in self?.model.moveUp(id) },
                KeyboardBarItem(symbol: "arrow.down", label: "Move down") { [weak self] in self?.model.moveDown(id) },
                KeyboardBarItem(symbol: "sparkles", label: "Ask AI") { [weak self] in self?.askAI() },
                KeyboardBarItem(symbol: "text.bubble", label: "Comment") { [weak self] in
                    guard let self else { return }
                    self.model.commentsBlock = id
                    self.model.showComments = true
                    self.textView?.resignFirstResponder()
                },
                KeyboardBarItem(symbol: "ellipsis.circle", label: "Block actions") { [weak self] in
                    self?.model.actionsFor = id
                    self?.textView?.resignFirstResponder()
                },
                KeyboardBarItem(symbol: "keyboard.chevron.compact.down", label: "Done") { [weak self] in
                    self?.textView?.resignFirstResponder()
                },
            ]
            let bar = KeyboardBar(items: items)
            return bar
        }
    }
}

