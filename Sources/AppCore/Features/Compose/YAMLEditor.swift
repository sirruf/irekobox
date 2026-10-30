import SwiftUI
import AppKit

/// A plain-text editor for YAML: monospaced, no smart quotes or other
/// substitutions, undo, light highlighting (keys, comments, strings), and
/// compose completion while typing (or on Esc / ⌃Space).
struct YAMLEditor: NSViewRepresentable {
    @Binding var text: String
    /// Local images, offered for `image:`.
    var images: [String] = []

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let textView = ComposeTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.images = images
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel(String(localized: "Compose file"))
        textView.string = text
        Self.highlight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView.documentView as? ComposeTextView)?.images = images
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        let selection = textView.selectedRanges
        textView.string = text
        textView.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        Self.highlight(textView)
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    /// Syntax colors that keep 4.5:1 on the editor background, light and dark.
    static let keyColor = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(hex: 0x6CB6FF) : NSColor(hex: 0x0B4F9C) }
    static let stringColor = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(hex: 0xE0A872) : NSColor(hex: 0x8A4B12) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            (textView as? ComposeTextView)?.noteChange(text)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            YAMLEditor.highlight(textView)
            (textView as? ComposeTextView)?.offerCompletionIfTyping()
        }
    }

    private static let comment = try! NSRegularExpression(pattern: #"(^|\s)#.*$"#, options: .anchorsMatchLines)
    private static let key = try! NSRegularExpression(pattern: #"^\s*(?:-\s+)?([A-Za-z0-9_.\-"']+)\s*:(?=\s|$)"#,
                                                      options: .anchorsMatchLines)
    private static let string = try! NSRegularExpression(pattern: #""[^"\n]*"|'[^'\n]*'"#)

    /// Recolor the whole text (compose files are small).
    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        let all = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: all)
        for match in string.matches(in: text, range: all) {
            storage.addAttribute(.foregroundColor, value: Self.stringColor, range: match.range)
        }
        for match in key.matches(in: text, range: all) {
            storage.addAttribute(.foregroundColor, value: Self.keyColor, range: match.range(at: 1))
        }
        for match in comment.matches(in: text, range: all) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
        storage.endEditing()
    }
}

/// The text view with compose completion: a list with descriptions opens
/// once a word is being typed (or on Esc / ⌃Space); ↑↓ choose, Return
/// inserts, Tab inserts the whole block, Esc closes, typing narrows it.
/// For `image:` it also searches Docker Hub, then the chosen image's tags.
final class ComposeTextView: NSTextView {
    var images: [String] = []
    private var typed = false
    private let popup = CompletionPopup()
    private var shown: ComposeCompletion.Suggestions?
    private let hub = ImageSuggester()
    private var hubTask: Task<Void, Never>?

    /// Note a single typed word character (however it got inserted).
    func noteChange(_ replacement: String?) {
        guard let replacement else { typed = false; return }
        typed = replacement.count == 1
            && replacement.rangeOfCharacter(from: .alphanumerics.union(CharacterSet(charactersIn: "_-/:."))) != nil
    }

    /// After an edit: keep the list in step with what's typed.
    func offerCompletionIfTyping() {
        let wasTyped = typed
        typed = false
        if popup.isVisible || wasTyped {
            showSuggestions(requireWord: true)
        }
    }

    private func showSuggestions(requireWord: Bool) {
        if let suggestions = ComposeCompletion.suggest(in: string, at: selectedRange().location, images: images),
           !requireWord || suggestions.range.length > 0 {
            present(suggestions)
        } else {
            hideSuggestions()
        }
        lookUpImage()
    }

    /// Docker Hub's matches for the image being typed, once typing pauses.
    private func lookUpImage() {
        hubTask?.cancel()
        guard let value = ComposeCompletion.imageValue(in: string, at: selectedRange().location),
              value.word.count >= 2 else { return }
        let local = images
        hubTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.hub.load(for: value.word, local: local)
            guard !Task.isCancelled,
                  let now = ComposeCompletion.imageValue(in: self.string, at: self.selectedRange().location),
                  now.word == value.word, now.range == value.range else { return }
            var seen = Set<String>()
            let items = self.hub.suggestions.map(Self.item).filter { seen.insert($0.label).inserted }
            guard !items.isEmpty else { return }
            self.present(ComposeCompletion.Suggestions(range: now.range, items: items))
        }
    }

    private static func item(_ suggestion: PullSuggestion) -> ComposeCompletion.Item {
        switch suggestion {
        case .local(let reference):
            return .init(label: reference, insert: reference, detail: String(localized: "On this Mac."))
        case .repository(let result):
            let about = [result.is_official ? String(localized: "Official image.") : nil, result.description.isEmpty ? nil : result.description]
            return .init(label: result.name, insert: result.name + ":",
                         detail: about.compactMap { $0 }.joined(separator: " "))
        case .tag(let name, let tag):
            return .init(label: "\(name):\(tag)", insert: "\(name):\(tag)", detail: String(localized: "Tag on Docker Hub."))
        }
    }

    private func present(_ suggestions: ComposeCompletion.Suggestions) {
        guard let window else { return }
        shown = suggestions
        var caret = firstRect(forCharacterRange: NSRange(location: suggestions.range.location, length: 0),
                              actualRange: nil)
        caret.origin.x -= 6
        popup.show(suggestions.items, below: caret, in: window) { [weak self] item, block in
            self?.accept(item, block: block)
        }
    }

    private func hideSuggestions() {
        hubTask?.cancel()
        shown = nil
        popup.hide()
    }

    private func accept(_ item: ComposeCompletion.Item, block: Bool) {
        guard let shown else { return }
        hideSuggestions()
        let ns = string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: shown.range.location, length: 0)).location
        var insert = item.insert
        if block || item.insert.contains("\n"), let body = item.block {
            insert = ComposeCompletion.expand(body, column: shown.range.location - lineStart,
                                              unit: ComposeCompletion.indentUnit(string))
        }
        guard shouldChangeText(in: shown.range, replacementString: insert) else { return }
        replaceCharacters(in: shown.range, with: insert)
        didChangeText()
        let caret = shown.range.location + (insert as NSString).length
        setSelectedRange(NSRange(location: caret, length: 0))
        if let volume = item.volume, let declaration = ComposeCompletion.volumeDeclaration(volume, in: string) {
            let at = NSRange(location: declaration.offset, length: 0)
            if shouldChangeText(in: at, replacementString: declaration.insert) {
                replaceCharacters(in: at, with: declaration.insert)
                didChangeText()
                let shift = declaration.offset <= caret ? (declaration.insert as NSString).length : 0
                setSelectedRange(NSRange(location: caret + shift, length: 0))
            }
        }
        // A key goes on to its values, an image repository to its tags.
        if insert.hasSuffix(": ") || insert.hasSuffix(":") { showSuggestions(requireWord: false) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .control, event.charactersIgnoringModifiers == " " {
            showSuggestions(requireWord: false)
            return
        }
        if popup.isVisible, flags.isDisjoint(with: [.command, .control, .option]) {
            switch event.keyCode {
            case 125: popup.move(1); return                       // ↓
            case 126: popup.move(-1); return                      // ↑
            case 36, 76: if let item = popup.selected { accept(item, block: false) }; return   // Return
            case 48: if let item = popup.selected { accept(item, block: true) }; return        // Tab
            case 53: hideSuggestions(); return                    // Esc
            case 123, 124: hideSuggestions()                      // ← → close, then move
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// Esc (the system's "complete") opens the list.
    override func complete(_ sender: Any?) {
        showSuggestions(requireWord: false)
    }

    override func resignFirstResponder() -> Bool {
        hideSuggestions()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        hideSuggestions()
        super.mouseDown(with: event)
    }
}

/// The floating list of suggestions under the caret.
@MainActor
final class CompletionPopup {
    struct Model {
        var items: [ComposeCompletion.Item] = []
        var selected = 0
    }

    private var model = Model() { didSet { render() } }
    private var panel: NSPanel?
    private var hosting: NSHostingView<CompletionList>?
    private var onPick: (ComposeCompletion.Item, Bool) -> Void = { _, _ in }

    var isVisible: Bool { panel?.isVisible == true }
    var selected: ComposeCompletion.Item? { model.items.indices.contains(model.selected) ? model.items[model.selected] : nil }

    static let width: CGFloat = 400
    static let rowHeight: CGFloat = 44

    func show(_ items: [ComposeCompletion.Item], below caret: NSRect, in window: NSWindow,
              onPick: @escaping (ComposeCompletion.Item, Bool) -> Void) {
        let keep = selected?.label
        let wasVisible = isVisible
        model = Model(items: items, selected: items.firstIndex { $0.label == keep } ?? 0)
        self.onPick = onPick
        if !wasVisible { announce() }
        let panel = self.panel ?? makePanel()
        let height = CGFloat(min(items.count, 6)) * Self.rowHeight + 30
        var origin = NSPoint(x: caret.minX, y: caret.minY - height - 2)
        if let screen = window.screen?.visibleFrame, origin.y < screen.minY {
            origin.y = caret.maxY + 2
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        // A fresh view each time: one kept across hide/show stops redrawing.
        let hosting = NSHostingView(rootView: list)
        panel.contentView = hosting
        self.hosting = hosting
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
        announce()
    }

    /// The list doesn't take focus, so VoiceOver hears the choice from here.
    private func announce() {
        guard let item = selected else { return }
        AccessibilityNotification.Announcement(item.detail.isEmpty ? item.label : "\(item.label). \(item.detail)").post()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        self.panel = panel
        return panel
    }

    private var list: CompletionList {
        CompletionList(model: model) { [weak self] index, block in
            guard let self, self.model.items.indices.contains(index) else { return }
            self.onPick(self.model.items[index], block)
        }
    }

    private func render() {
        hosting?.rootView = list
    }
}

struct CompletionList: View {
    let model: CompletionPopup.Model
    let pick: (Int, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == model.selected)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { pick(index, false) }
                        }
                    }
                }
                .onChange(of: model.selected) { _, index in proxy.scrollTo(index) }
            }
            Divider()
            HStack(spacing: DS.Spacing.m) {
                Text("↩ insert")
                if model.items.indices.contains(model.selected), model.items[model.selected].block != nil {
                    Text("⇥ insert block")
                }
                Text("esc close")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: 24)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.separator))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ item: ComposeCompletion.Item, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Spacing.xs) {
                Text(item.label).font(.system(.callout, design: .monospaced).weight(.semibold))
                if item.block != nil {
                    Image(systemName: "text.badge.plus").font(.caption2)
                        .help("Tab inserts a ready block")
                }
                Spacer(minLength: 0)
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(.caption).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, DS.Spacing.s)
        .frame(height: CompletionPopup.rowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
