import Foundation

/// What Docker does the first time a container mounts an empty volume: the
/// image's folder at the mount path is copied in, with its owner and mode.
/// `container` doesn't, and a new ext4 volume holds an empty `lost+found`
/// (postgres refuses a data folder that isn't empty), so Irekobox fills
/// fresh volumes itself with a short-lived helper container of the image.
///
/// Shared by the Docker API and StackKit; each runs the helper its own way.
public enum VolumeCopyUp {
    /// Where the helper mounts the volume being filled.
    public static let mountPoint = "/.irekobox-copyup"

    /// The shell script the helper runs as root: remove `lost+found`, then,
    /// if the image has a folder at `sourcePath`, copy it in keeping owners
    /// and modes, and give the mount point that folder's owner and mode. An
    /// image without the folder leaves the volume empty, as Docker does.
    public static func script(sourcePath: String) -> String {
        """
        rmdir \(mountPoint)/lost+found 2>/dev/null
        s=\(shellQuote(sourcePath)); [ -d "$s" ] || exit 0
        cp -a "$s"/. \(mountPoint)/ && chown "$(stat -c %u:%g "$s")" \(mountPoint) \\
          && chmod "$(stat -c %a "$s")" \(mountPoint)
        """
    }

    /// `container create`/`run` arguments after the verb and any options of
    /// the caller's own: the helper's name, `/bin/sh` as root with the volume
    /// mounted, then the image and the script.
    public static func helperArguments(name: String, volume: String, image: String, sourcePath: String) -> [String] {
        ["--name", name, "--entrypoint", "/bin/sh", "--user", "0",
         "--volume", "\(volume):\(mountPoint)", image, "-c", script(sourcePath: sourcePath)]
    }

    /// `<container>-copyup-<index>`: the helper filling a container's volume.
    public static func helperName(container: String, index: Int) -> String {
        "\(container)-copyup-\(index)"
    }

    /// A stable name for an anonymous volume of `container` at `path`, so a
    /// container made again keeps its data (as Compose reattaches anonymous
    /// volumes when it recreates a service).
    public static func anonymousVolumeName(container: String, path: String) -> String {
        let hash = path.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "\(container)-anon-\(String(hash, radix: 16).prefix(10))"
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
