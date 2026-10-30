import SwiftUI
import CoreImage

/// A small status dot. Never the only signal: pair it with a label.
struct StatusDot: View {
    let tone: Tone
    var size: CGFloat = 8

    var body: some View {
        Group {
            switch tone {
            case .neutral, .inactive:
                // Hollow for "not running" so it reads without color.
                Circle().strokeBorder(tone.fill, lineWidth: 1.5)
            case .critical:
                // A mark, not just red: trouble reads without color too.
                Image(systemName: "exclamationmark.circle.fill").resizable().foregroundStyle(tone.fill)
            case .warning:
                // Half filled: on its way, not there yet.
                ZStack {
                    Circle().strokeBorder(tone.fill, lineWidth: 1.5)
                    Circle().trim(from: 0, to: 0.5).rotation(.degrees(90)).fill(tone.fill)
                }
            default:
                Circle().fill(tone.fill)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Dot + label in a tinted capsule: "● Running · healthy".
struct StatusPill: View {
    let tone: Tone
    let label: String
    var detail: String?

    init(tone: Tone, label: LocalizedStringResource, detail: String? = nil) {
        self.init(tone: tone, label: String(localized: label), detail: detail)
    }

    /// A label that is data, or already localized.
    @_disfavoredOverload
    init(tone: Tone, label: String, detail: String? = nil) {
        self.tone = tone
        self.label = label
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(tone: tone, size: 6)
            Text(verbatim: detail.map { "\(label) · \($0)" } ?? label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone.text)
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 2)
        .background(Capsule().fill(tone.background))
        .accessibilityElement(children: .combine)
    }
}

/// A published port, ":3000 ↗". Clicking it offers what to do with the
/// address: open it, copy it, or show a QR code for a phone on the same network.
struct PortPill: View {
    let port: PortLink
    /// What it leads to inside ("web"), shown in the popover.
    var target: String?
    @State private var showing = false
    /// `.increased` on a selected (accent-filled) table row.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let url = port.url {
            Button {
                showing = true
            } label: {
                label(arrow: true)
            }
            .buttonStyle(.plain)
            .help("Open \(url.absoluteString)")
            .accessibilityLabel("\(port.accessibilityDescription): open, copy or share")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                PortPopover(port: port, url: url, target: target)
            }
        } else {
            label(arrow: false)
                .accessibilityLabel(port.accessibilityDescription)
        }
    }

    private var onAccent: Bool { prominence == .increased }

    private func label(arrow: Bool) -> some View {
        HStack(spacing: 3) {
            Text(port.label).font(DS.Font.monoSmall)
            if arrow {
                Image(systemName: "arrow.up.right").imageScale(.small).font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(onAccent ? Color.white : arrow ? DS.accent : Color.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(minHeight: 20)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small)
                .strokeBorder(onAccent ? Color.white.opacity(0.6) : arrow ? DS.accent.opacity(0.35) : DS.separator)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small))
    }
}

private struct PortPopover: View {
    let port: PortLink
    let url: URL
    let target: String?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var showQR = false

    /// http://192.168.1.24:8080 when the port listens on every interface.
    private var networkURL: URL? {
        guard port.hostAddress == nil, let address = LocalNetwork.address else { return nil }
        return URL(string: "http://\(address):\(port.hostPort)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.s) {
                Text(verbatim: "\(url.host() ?? "localhost"):\(port.hostPort)")
                    .font(DS.Font.mono.weight(.medium)).foregroundStyle(DS.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(DS.accent.opacity(0.12)))
                Text(verbatim: "→ \(target ?? String(localized: "container")) : \(port.containerPort)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Spacing.s) {
                Button("Open in Browser") {
                    Milestone.openedInBrowser.reach()
                    openURL(url)
                    dismiss()
                }
                .buttonStyle(.automatic)
                .keyboardShortcut(.defaultAction)
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    dismiss()
                }
                .buttonStyle(.automatic)
            }
            if let networkURL {
                Button(showQR ? "Hide QR Code" : "Show QR for iPhone") { withAnimation(.snappy) { showQR.toggle() } }
                    .buttonStyle(.automatic)
                if showQR, let image = QRCode.image(networkURL.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable()
                        .frame(width: 150, height: 150)
                        .accessibilityLabel("QR code for \(networkURL.absoluteString)")
                }
                Text("Also reachable on your network as \(networkURL.host() ?? ""):\(String(port.hostPort)) — anyone on the same Wi‑Fi can open it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if port.hostAddress != nil {
                Text("Only this Mac can open it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.l)
        .frame(width: 300, alignment: .leading)
    }
}

/// The popover on its own, for snapshots.
struct PortPopoverPreview: View {
    let port: PortLink
    var body: some View { PortPopover(port: port, url: port.url!, target: "web") }
}

/// This Mac's address on the local network (Wi‑Fi or Ethernet).
enum LocalNetwork {
    static var address: String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [String: String] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[name] = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return found.keys.sorted().first.flatMap { found[$0] }
    }
}

/// A QR code, drawn by Core Image.
enum QRCode {
    static func image(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A notice row: icon tone, title, explanation, optional actions.
struct NoticeBanner<Actions: View>: View {
    let tone: Tone
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(tone.fill)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title).font(.callout.weight(.medium))
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.s)
            actions()
        }
        .padding(DS.Spacing.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(tone.background))
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch tone {
        case .positive: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .info, .neutral, .inactive: return "info.circle.fill"
        }
    }
}

extension NoticeBanner {
    init(tone: Tone, title: LocalizedStringResource, message: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(tone: tone, title: String(localized: title), message: message, actions: actions)
    }
}

extension NoticeBanner where Actions == EmptyView {
    init(tone: Tone, title: LocalizedStringResource, message: String? = nil) {
        self.init(tone: tone, title: String(localized: title), message: message) { EmptyView() }
    }

    @_disfavoredOverload
    init(tone: Tone, title: String, message: String? = nil) {
        self.init(tone: tone, title: title, message: message) { EmptyView() }
    }
}

#Preview("Status") {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            StatusPill(tone: .positive, label: "Running", detail: "healthy")
            StatusPill(tone: .warning, label: "Running", detail: "restarted 2×")
            StatusPill(tone: .neutral, label: "Stopped")
            StatusPill(tone: .critical, label: "Unhealthy")
        }
        HStack {
            PortPill(port: PortLink(.init(containerPort: 80, hostPort: 3000, hostAddress: "0.0.0.0", proto: "tcp", count: 1)))
            PortPill(port: PortLink(.init(containerPort: 53, hostPort: 5353, hostAddress: nil, proto: "udp", count: 1)))
        }
        NoticeBanner(tone: .warning, title: "worker restarted 2 times",
                     message: "Exit code 137 — usually out of memory.") {
            Button("View Logs") {}
        }
    }
    .padding()
    .frame(width: 520)
}
