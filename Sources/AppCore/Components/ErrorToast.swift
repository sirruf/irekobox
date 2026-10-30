import SwiftUI
import AppKit

/// A transient error banner pinned to the bottom of a screen. It auto-dismisses
/// after a few seconds and can be dismissed immediately with its close button —
/// so an error never lingers indefinitely or covers list content for good.
struct ErrorToast: View {
    let message: String
    /// Called when the toast should disappear (timeout or close button).
    var onDismiss: () -> Void
    @State private var hovering = false

    /// How long the toast stays before auto-dismissing: longer for longer text.
    private var lifetime: Duration { .seconds(min(15, 6 + message.count / 25)) }

    var body: some View {
        ToastCard(title: nil, message: message, onDismiss: onDismiss)
            .accessibilityIdentifier("errorToast")
            .onHover { hovering = $0 }
            .onAppear { AccessibilityNotification.Announcement(message).post() }
            // Restarts whenever the message changes; waits while hovered or
            // while VoiceOver is on, so it can be read.
            .task(id: "\(message)\(hovering)") {
                guard !hovering, !NSWorkspace.shared.isVoiceOverEnabled else { return }
                try? await Task.sleep(for: lifetime)
                if !Task.isCancelled { onDismiss() }
            }
            .task {
                // A problem toast with fixes already says this.
                if Problem.handled.contains(where: { !$0.isEmpty && message.contains($0) }) { onDismiss() }
            }
    }
}

/// A problem with its fixes: stays until dismissed or fixed.
struct ProblemToast: View {
    let problem: Problem
    var onDismiss: () -> Void

    var body: some View {
        ToastCard(title: problem.title, message: problem.message, fixes: problem.fixes, onDismiss: onDismiss)
            .accessibilityIdentifier("problemToast")
            .onAppear { AccessibilityNotification.Announcement("\(problem.title). \(problem.message)" as String).post() }
    }
}

/// The red card both toasts use: "!", a bold title, what happened, fixes.
private struct ToastCard: View {
    let title: String?
    let message: String
    var fixes: [Problem.Fix] = []
    var onDismiss: () -> Void

    private var copied: String { [title, message].compactMap { $0 }.joined(separator: "\n") }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "!").font(.body.weight(.heavy)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(verbatim: title).font(.callout.weight(.bold)) }
                Text(verbatim: message).font(.callout).lineLimit(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !fixes.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(fixes) { fix in
                            Button(fix.title) {
                                fix.action()
                                onDismiss()
                            }
                            .buttonStyle(ToastButtonStyle())
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copied, forType: .string)
                }
                .buttonStyle(.plain).font(.caption)
                .help("Copy the message")
                .accessibilityLabel("Copy error")
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.caption.weight(.semibold))
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
            }
            .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 520, alignment: .leading)
        // A dark red in both appearances keeps white text above 4.5:1.
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: NSColor(hex: 0xA61B1B)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4))
        .padding(.bottom, 12)
    }
}

private struct ToastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(configuration.isPressed ? 0.3 : 0.18)))
    }
}

extension View {
    /// Overlay a bottom-pinned, auto-dismissing ``ErrorToast`` driven by an
    /// optional message binding. Setting the binding back to `nil` hides it.
    func errorToast(_ message: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            if let text = message.wrappedValue {
                ErrorToast(message: text) { message.wrappedValue = nil }
            }
        }
    }
}
