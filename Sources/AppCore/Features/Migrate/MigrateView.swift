import SwiftUI
import AppKit
import MigrationKit

/// Paste a `docker run …` command, translate it to `container run …`,
/// review warnings, then copy or run it.
struct DockerRunTranslateView: View {
    @Environment(AppState.self) private var app
    @State private var model: MigrateViewModel?

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .onAppear { if model == nil { model = MigrateViewModel(cli: app.cli) } }
    }

    private func content(_ model: MigrateViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                Text("Paste a `docker run` command")
                    .font(.headline)

                TextEditor(text: Binding(get: { model.input }, set: { model.input = $0 }))
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 90)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .accessibilityIdentifier("migrate.translateInput")

                Button {
                    model.translate()
                } label: {
                    Label("Translate", systemImage: "arrow.right.arrow.left")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("migrate.translateButton")

                if let translation = model.translation {
                    resultCard(model, translation)
                    if !translation.warnings.isEmpty {
                        warnings(translation.warnings)
                    }
                }

                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.critical.text).font(.callout)
                }
                if let result = model.runResult {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.positive.text).font(.callout)
                }
            }
            .padding(DS.Spacing.l)
        }
    }

    private func resultCard(_ model: MigrateViewModel, _ translation: DockerRunTranslation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Translated command").font(.subheadline).foregroundStyle(.secondary)
            Text(translation.displayCommand)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translation.displayCommand, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }

                Spacer()

                Button {
                    Task { await model.run() }
                } label: {
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning || !app.servicesRunning)
            }
        }
        .panel(padding: DS.Spacing.l)
        .accessibilityIdentifier("migrate.resultCard")
    }

    private func warnings(_ warnings: [MigrationWarning]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Warnings (\(warnings.count))").font(.subheadline).foregroundStyle(.secondary)
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon(warning.severity)).foregroundStyle(color(warning.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "--\(warning.flag)").font(.callout.weight(.medium))
                        Text(warning.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .panel(padding: DS.Spacing.l)
    }

    private func icon(_ severity: MigrationWarning.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .partial: return "exclamationmark.triangle"
        case .unsupported: return "xmark.octagon"
        }
    }

    private func color(_ severity: MigrationWarning.Severity) -> Color {
        switch severity {
        case .info: return .secondary
        case .partial: return Tone.warning.text
        case .unsupported: return Tone.critical.text
        }
    }
}
