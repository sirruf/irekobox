import Foundation

/// Streaming `container build` / `image push` — both emit BuildKit-style
/// `--progress plain` lines (on stderr), surfaced for a live progress UI.
public struct BuildRepository: Sendable {
    public struct Options: Sendable {
        public var contextPath: String
        public var dockerfilePath: String?
        public var tag: String
        public var architectures: [String]
        public var noCache: Bool
        /// `KEY=value` build arguments.
        public var buildArguments: [String] = []
        /// `key=value` image labels.
        public var labels: [String] = []
        public var target: String?
        /// Pull newer base images.
        public var pull = false
        /// `os/arch[/variant]`; takes precedence over `architectures`.
        public var platforms: [String] = []

        public init(contextPath: String, dockerfilePath: String? = nil, tag: String,
                    architectures: [String] = [], noCache: Bool = false) {
            self.contextPath = contextPath
            self.dockerfilePath = dockerfilePath
            self.tag = tag
            self.architectures = architectures
            self.noCache = noCache
        }
    }

    private let stream: CLIStream

    public init(stream: CLIStream) {
        self.stream = stream
    }

    /// `container build --progress plain -t <tag> [-f <file>] [--arch …] [--no-cache] <context>`.
    public func build(_ options: Options) -> AsyncThrowingStream<String, Error> {
        var arguments = ["build", "--progress", "plain", "--tag", options.tag]
        if let dockerfile = options.dockerfilePath { arguments += ["--file", dockerfile] }
        for arch in options.architectures { arguments += ["--arch", arch] }
        for platform in options.platforms { arguments += ["--platform", platform] }
        for argument in options.buildArguments { arguments += ["--build-arg", argument] }
        for label in options.labels { arguments += ["--label", label] }
        if let target = options.target { arguments += ["--target", target] }
        if options.pull { arguments.append("--pull") }
        if options.noCache { arguments.append("--no-cache") }
        arguments.append(options.contextPath)
        return stream.lines(arguments, mergeStderr: true)
    }

    /// `container image push --progress plain <reference>`.
    public func push(_ reference: String) -> AsyncThrowingStream<String, Error> {
        stream.lines(["image", "push", "--progress", "plain", reference], mergeStderr: true)
    }
}
