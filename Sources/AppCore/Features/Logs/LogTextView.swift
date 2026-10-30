import SwiftUI
import AppKit

/// Read-only log text backed by `NSTextView`: new lines are appended to the
/// text storage (and dropped lines removed from its start) instead of
/// re-rendering everything, so large, fast logs stay smooth.
///
/// Scrolling away from the end pauses following; scrolling back resumes it.
struct LogTextView: NSViewRepresentable {
    let model: LogViewerModel
    /// Follows a note's "Show … logs" link.
    var openContainer: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = Self.makeTextView()
        context.coordinator.attach(scrollView: scrollView, textView: textView)
        return scrollView
    }

    /// TextKit 1 with non-contiguous layout: following a 50k-line log stays at a
    /// few ms per batch, where TextKit 2 re-laid out the whole document on every
    /// scroll to the end (seconds).
    static func makeTextView() -> (NSScrollView, NSTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView(usingTextLayoutManager: false)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityIdentifier("logs.text")
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Read the observed properties here so SwiftUI re-runs this on change.
        _ = (model.generation, model.buffer.entries.count, model.buffer.firstID, model.buffer.entries.last?.id, model.isFollowing, model.wrapLines)
        context.coordinator.openContainer = openContainer
        context.coordinator.update()
    }

    static let linkScheme = "irekobox-log"

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var openContainer: ((String) -> Void)?
        let model: LogViewerModel
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        /// Rendered lines, oldest first: entry id and character length (incl. newline).
        private var rendered: [(id: Int, length: Int)] = []
        private var renderedGeneration = -1
        private var lastRenderedID = -1
        private var wrapping: Bool?
        private var programmaticScroll = false

        init(model: LogViewerModel) {
            self.model = model
        }

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            textView.delegate = self
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                   name: NSView.boundsDidChangeNotification,
                                                   object: scrollView.contentView)
        }

        func update() {
            guard let textView, let storage = textView.textStorage else { return }
            applyWrapping()
            storage.beginEditing()
            if renderedGeneration != model.generation {
                renderAll(storage)
            } else {
                dropTrimmed(storage)
                appendNew(storage)
            }
            storage.endEditing()
            if model.isFollowing { scrollToEnd() }
        }

        private func renderAll(_ storage: NSTextStorage) {
            let entries = model.visibleEntries
            let text = NSMutableAttributedString()
            rendered = []
            for entry in entries {
                let line = attributed(entry)
                rendered.append((entry.id, line.length))
                text.append(line)
            }
            storage.setAttributedString(text)
            renderedGeneration = model.generation
            lastRenderedID = model.buffer.entries.last?.id ?? lastRenderedID
        }

        private func dropTrimmed(_ storage: NSTextStorage) {
            let firstKept = model.buffer.firstID
            var dropLength = 0
            var dropCount = 0
            for line in rendered {
                guard line.id < firstKept else { break }
                dropLength += line.length
                dropCount += 1
            }
            guard dropCount > 0 else { return }
            rendered.removeFirst(dropCount)
            storage.deleteCharacters(in: NSRange(location: 0, length: min(dropLength, storage.length)))
        }

        private func appendNew(_ storage: NSTextStorage) {
            guard let newest = model.buffer.entries.last?.id, newest > lastRenderedID else { return }
            let fresh = model.buffer.entries.reversed().prefix { $0.id > lastRenderedID }.reversed()
            let text = NSMutableAttributedString()
            for entry in fresh where model.displayFilter.matches(entry) {
                let line = attributed(entry)
                rendered.append((entry.id, line.length))
                text.append(line)
            }
            storage.append(text)
            lastRenderedID = newest
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == LogTextView.linkScheme else { return false }
            openContainer?(url.lastPathComponent)
            return true
        }

        /// An app note: an info symbol and the sentence on a tinted band, with
        /// a link to the container it's about.
        private func attributedNote(_ entry: LogEntry, _ note: LogNote) -> NSAttributedString {
            let font = NSFont.systemFont(ofSize: 12)
            let tint = NSColor.controlAccentColor.withAlphaComponent(0.12)
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = 3
            paragraph.paragraphSpacing = 3
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor,
                                                       .backgroundColor: tint, .paragraphStyle: paragraph]
            let line = NSMutableAttributedString()
            if model.showTimestamps {
                line.append(NSAttributedString(string: LogViewerModel.timeFormatter.string(from: entry.time) + "  ",
                                               attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                                                            .foregroundColor: NSColor.secondaryLabelColor,
                                                            .paragraphStyle: paragraph]))
            }
            let symbol = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: String(localized: "Note", comment: "An explanatory line the app adds to a log"))?
                .withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
            if let symbol {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                attachment.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
                let icon = NSMutableAttributedString(attachment: attachment)
                icon.addAttributes(base, range: NSRange(location: 0, length: icon.length))
                line.append(icon)
            }
            line.append(NSAttributedString(string: " " + entry.text, attributes: base))
            if let id = note.containerID, let title = note.linkTitle,
               let url = URL(string: "\(LogTextView.linkScheme)://container/\(id)") {
                line.append(NSAttributedString(string: "  ", attributes: base))
                var link = base
                link[.link] = url
                line.append(NSAttributedString(string: title, attributes: link))
            }
            line.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
            return line
        }

        private func attributed(_ entry: LogEntry) -> NSAttributedString {
            if let note = entry.note { return attributedNote(entry, note) }
            let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            let color: NSColor
            switch entry.level {
            case .error: color = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: 0xFF6961) : NSColor(hex: 0xA61B1B) }
            case .warning: color = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: 0xFFB340) : NSColor(hex: 0x8A4A04) }
            case .info: color = .labelColor
            }
            let line = NSMutableAttributedString()
            if model.showTimestamps {
                line.append(NSAttributedString(string: LogViewerModel.timeFormatter.string(from: entry.time) + "  ",
                                               attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let start = line.length
            line.append(NSAttributedString(string: entry.text + "\n", attributes: [.font: font, .foregroundColor: color]))
            // Each service's label in its own color, as the window's chips.
            let width = model.labelWidth
            if width > 0, (entry.text as NSString).length > width + 2,
               (entry.text as NSString).substring(with: NSRange(location: width, length: 3)) == " | " {
                let label = (entry.text as NSString).substring(to: width).trimmingCharacters(in: .whitespaces)
                line.addAttribute(.foregroundColor, value: LogLabelColor.color(for: label, in: model.labels),
                                  range: NSRange(location: start, length: width))
            }
            let query = model.displayFilter.query
            if !query.isEmpty {
                let body = line.string as NSString
                var range = NSRange(location: start, length: body.length - start)
                while true {
                    let match = body.range(of: query, options: .caseInsensitive, range: range)
                    guard match.location != NSNotFound else { break }
                    line.addAttributes([.backgroundColor: NSColor.findHighlightColor,
                                        .foregroundColor: NSColor.black], range: match)
                    let next = match.location + match.length
                    range = NSRange(location: next, length: body.length - next)
                }
            }
            return line
        }

        private func applyWrapping() {
            guard let textView, let scrollView, wrapping != model.wrapLines else { return }
            wrapping = model.wrapLines
            let container = textView.textContainer
            if model.wrapLines {
                container?.widthTracksTextView = true
                container?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
                textView.isHorizontallyResizable = false
                textView.frame.size.width = scrollView.contentSize.width
            } else {
                container?.widthTracksTextView = false
                container?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
                textView.isHorizontallyResizable = true
            }
        }

        private func scrollToEnd() {
            guard let textView else { return }
            programmaticScroll = true
            textView.scrollToEndOfDocument(nil)
            programmaticScroll = false
        }

        @objc private func boundsChanged() {
            guard !programmaticScroll, let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            let atEnd = visible.maxY >= document.bounds.height - 24
            if model.isFollowing != atEnd { model.isFollowing = atEnd }
        }
    }
}

/// Stable colors for service labels in merged logs (and their chips).
enum LogLabelColor {
    private static let palette: [(light: UInt32, dark: UInt32)] = [
        (0x0A5BC2, 0x5AA9FF), (0x7A3FB8, 0xC59BFF), (0xA0520A, 0xFFB066),
        (0x1A7F37, 0x5BD27A), (0x0E7C86, 0x5CD0D9), (0xB0306A, 0xFF7EB6),
    ]

    /// By position among `labels`, so a project's services never share one.
    static func index(for label: String, in labels: [String]) -> Int {
        if let position = labels.firstIndex(of: label) { return position % palette.count }
        return Int(label.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % UInt32(palette.count))
    }

    static func color(for label: String, in labels: [String]) -> NSColor {
        let pair = palette[index(for: label, in: labels)]
        return NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: pair.dark) : NSColor(hex: pair.light)
        }
    }
}
