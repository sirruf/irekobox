import SwiftUI

/// Warns that a stack uses host bind mounts, which on macOS `container` can't be
/// chown/chmod'd (virtiofs). Shown in the stack detail and the import dialog.
struct BindMountHint: View {
    let mounts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Host bind mounts", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(Tone.warning.text)
                .accessibilityIdentifier("stacks.bindMountHint")
            Text("On macOS, `container` mounts host folders via virtiofs, where chown/chmod aren't permitted. A service that must own its data directory (databases, etc.) can fail. Run it as its data uid (`user:`) for a fresh dir, or use a named volume. To reuse existing data, dump & restore.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(mounts, id: \.self) { mount in
                Text(verbatim: "• \(mount)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}
