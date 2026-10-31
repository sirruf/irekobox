import SwiftUI

/// Warns that a stack uses host bind mounts: through virtiofs a container can
/// chown inside a shared folder but not the shared folder itself, so a database
/// whose data directory is the mount point fails. Shown in the stack detail.
struct BindMountHint: View {
    let mounts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Host bind mounts", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(Tone.warning.text)
                .accessibilityIdentifier("stacks.bindMountHint")
            Text("Folders from this Mac are shared through virtiofs: inside them a container can change owners and permissions, but not on the shared folder itself. A database whose data directory is the shared folder itself, such as Postgres, fails to start. Share the folder one level up and point the data directory at a subfolder, for example `~/pg:/pg` with `PGDATA: /pg/data`.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(mounts, id: \.self) { mount in
                Text(verbatim: "• \(mount)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}
