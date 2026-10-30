import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ContainerKit

/// Paste or open manifests, check them on the server, apply them.
struct ApplyYAMLSheet: View {
    let cluster: String
    let model: ClusterModel
    @State var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var checked: String?
    @State private var problem: String?
    @State private var warnings: [String] = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Apply YAML").font(.title3.weight(.semibold))
            YAMLEditor(text: $text)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.separator))
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if let problem {
                    Label(problem, systemImage: "xmark.octagon").foregroundStyle(Tone.critical.text)
                        .lineLimit(4).textSelection(.enabled)
                } else if checked == text, !text.isEmpty {
                    Label("\(cluster) accepts it (dry run)", systemImage: "checkmark").foregroundStyle(Tone.positive.text)
                } else if working {
                    HStack(spacing: DS.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Asking \(cluster)…").foregroundStyle(.secondary)
                    }
                } else if text.isEmpty {
                    Text("Paste manifests or open a file; \(cluster) checks them as you type, without changing anything.")
                        .foregroundStyle(.secondary)
                }
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.text)
                }
            }
            .font(.callout)
            HStack {
                Button("Open File…") { open() }.buttonStyle(.automatic)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.automatic).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    Task {
                        working = true
                        if await model.apply(text) { dismiss() } else { problem = model.error }
                        working = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.isEmpty || working || problem != nil)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 720, height: 600)
        // The server checks it a moment after typing stops: nothing changes.
        .task(id: text) {
            checked = nil
            problem = nil
            warnings = []
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            working = true
            let found = await model.check(text)
            guard !Task.isCancelled else { return }
            problem = found
            checked = found == nil ? text : nil
            warnings = found == nil ? await model.portWarnings(in: text) : []
            working = false
        }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .json, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        text = panel.urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n---\n")
    }
}
