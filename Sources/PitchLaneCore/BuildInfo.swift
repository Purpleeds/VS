import Foundation

/// Version + build number, read from Info.plist (CFBundleShortVersionString / CFBundleVersion).
public struct BuildInfo: Sendable, Equatable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    /// Pass `Bundle.main.infoDictionary`. Missing or non-string values fall back to "0.0.0" / "0".
    public init(infoDictionary: [String: Any]?) {
        self.version = (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        self.build = (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// e.g. "v0.1.0 (3)"
    public var display: String { "v\(version) (\(build))" }

    /// e.g. "build 3"
    public var buildLabel: String { "build \(build)" }
}
