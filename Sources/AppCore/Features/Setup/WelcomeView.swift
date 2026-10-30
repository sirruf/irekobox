import SwiftUI

/// A four-page introduction on the first launch with the engine ready: what
/// the app is, the four ways to run things, how to reach them, and how it
/// teaches as you go. Skippable; shown once.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    /// -welcomePage N opens on another page (screenshots).
    @State private var page = max(0, min(3, UserDefaults.standard.integer(forKey: "welcomePage") - 1))
    static let shownKey = "welcomeShown"

    private let pages = 4

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Text("Welcome to Irekobox · \(page + 1) of \(pages)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(DS.accent)
            Group {
                switch page {
                case 0: intro
                case 1: fourWays
                case 2: reach
                default: learning
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            HStack {
                Button("Skip Introduction") { finish() }
                    .buttonStyle(.link)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { index in
                        Capsule().fill(index == page ? DS.accent : Color.secondary.opacity(0.35))
                            .frame(width: index == page ? 18 : 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(page + 1) of \(pages)")
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation(.snappy) { page -= 1 } }
                        .buttonStyle(.automatic)
                }
                Button(page == pages - 1 ? "Start" : "Continue") {
                    if page == pages - 1 { finish() } else { withAnimation(.snappy) { page += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(width: 820)
        .background(DS.dynamic(light: 0xFBFBFD, dark: 0x1E1E20))
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        dismiss()
    }

    private func heading(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: DS.Spacing.s) {
            Text(title).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
            Text(subtitle).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
    }

    // MARK: - Pages

    private var intro: some View {
        VStack(spacing: DS.Spacing.xl) {
            BrandLogo(size: 72)
            heading("Containers on your Mac, the Apple way",
                    "Run the apps you'd run with Docker — web servers, databases, whole projects — on Apple's own container engine.")
            HStack(alignment: .top, spacing: DS.Spacing.l) {
                point("bolt.fill", "Fast and light", "Each container is a small virtual machine that starts in about a second.")
                point("lock.fill", "Kept apart", "Every container is isolated from your Mac and from the others.")
                point("arrow.left.arrow.right", "Docker tools work", "docker and docker compose talk to it once you turn on the Docker API.")
            }
        }
    }

    private var fourWays: some View {
        VStack(spacing: DS.Spacing.l) {
            heading("Four ways to run things on your Mac",
                    "They all use the same engine underneath. Start with whichever matches what you are doing — you can try every one from the Overview later.")
            HStack(alignment: .top, spacing: DS.Spacing.m) {
                way(.container, "Container", "One app, isolated, from an image. A web server, a database, a tool.", Text(verbatim: "docker run"))
                way(.compose, "Compose project", "Several containers that belong together — your app, its database, a cache — from one compose.yaml.", Text(verbatim: "docker compose up"))
                way(.machine, "Machine", "A whole Linux system with your account and home folder. For a shell, tools and experiments.", Text("a lightweight VM"))
                way(.kubernetes, "Kubernetes", "A small cluster here, to try apps the way they run in production. Every step is explained.", Text("kind or minikube"))
            }
        }
    }

    private var reach: some View {
        VStack(spacing: DS.Spacing.xl) {
            heading("Open what you run",
                    "A container is only useful if you can reach it. Irekobox shows the way in on every card.")
            HStack(alignment: .top, spacing: DS.Spacing.l) {
                point("network", Text(verbatim: "localhost:8080"), "A published port opens in your browser like any local server.")
                point("globe", Text(verbatim: "web.shop.test"), "Every container also gets a name, so web and api find each other — and you find them.")
                point("terminal", "A shell inside", "Open a terminal in any running container, in the window or its own.")
            }
        }
    }

    private var learning: some View {
        VStack(spacing: DS.Spacing.xl) {
            heading("Learn as you go",
                    "New to containers? The app explains itself while you work, and steps back once you know your way around.")
            HStack(alignment: .top, spacing: DS.Spacing.l) {
                point("text.bubble", "Notes on each screen", "Short blue notes say what a screen is for and how its parts fit.")
                point("info.circle", "Terms explained", "An ⓘ beside words like Service or Volume tells you what they mean.")
                point("checklist", "First Steps", "Five things to try on the Overview, ticked off as you do them.")
            }
            Text("Turn any of these off in Settings › Learning.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        point(symbol, Text(title), text)
    }

    /// A point whose title is data (an address), not words to translate.
    private func point(_ symbol: String, _ title: Text, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Image(systemName: symbol).font(.title2).foregroundStyle(DS.accent)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.accent.opacity(0.1)))
                .accessibilityHidden(true)
            title.font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func way(_ kind: WayArt.Kind, _ title: LocalizedStringKey, _ text: LocalizedStringKey, _ like: Text) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            WayArt(kind: kind)
                .frame(maxWidth: .infinity, minHeight: 90)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("**Like** \(like.foregroundStyle(.secondary))", comment: "On a card: a familiar tool this way resembles").font(.caption)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.raised)
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1))
    }
}

/// The little drawings on the four ways: a container, three linked services,
/// a terminal, a cluster's wheel over its nodes.
private struct WayArt: View {
    enum Kind { case container, compose, machine, kubernetes }
    let kind: Kind
    private let fill = DS.accent.opacity(0.1)

    var body: some View {
        switch kind {
        case .container:
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(fill).strokeBorder(DS.accent, lineWidth: 2).frame(width: 56, height: 50)
                Hexagon().stroke(DS.accent, lineWidth: 2).frame(width: 24, height: 26)
            }
        case .compose:
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 38, y: 34)); path.addLine(to: CGPoint(x: 50, y: 26))
                    path.move(to: CGPoint(x: 78, y: 26)); path.addLine(to: CGPoint(x: 90, y: 34))
                }
                .stroke(DS.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                box.offset(x: -36, y: 10)
                box.offset(x: 0, y: -10)
                box.offset(x: 36, y: 10)
            }
            .frame(width: 128, height: 70)
        case .machine:
            VStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.11, green: 0.12, blue: 0.14)).frame(width: 84, height: 50)
                    Text(verbatim: ">_").font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.49, green: 0.88, blue: 0.54)).padding(.leading, 12)
                }
                Capsule().fill(Color.primary.opacity(0.7)).frame(width: 30, height: 3)
            }
        case .kubernetes:
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(DS.accent, lineWidth: 2).frame(width: 36, height: 36)
                    Circle().fill(DS.accent).frame(width: 10, height: 10)
                    ForEach(0..<4) { index in
                        Rectangle().fill(DS.accent).frame(width: 2, height: 12)
                            .offset(y: -24).rotationEffect(.degrees(Double(index) * 90))
                    }
                }
                HStack(spacing: 6) { ForEach(0..<3) { _ in node } }
            }
        }
    }

    private var box: some View {
        RoundedRectangle(cornerRadius: 7).fill(fill).strokeBorder(DS.accent, lineWidth: 1.6).frame(width: 30, height: 26)
    }

    private var node: some View {
        RoundedRectangle(cornerRadius: 3).fill(fill).strokeBorder(DS.accent, lineWidth: 1).frame(width: 16, height: 10)
    }
}

private struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3 - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
