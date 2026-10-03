import Foundation

public enum RestoreProvider: String, CaseIterable, Identifiable {
    case local = "Local (Apple Silicon)"
    case nvidia = "Cloud / NVIDIA"

    public var id: String { rawValue }
}

public struct RestoreCommand {
    public let provider: RestoreProvider
    public let input: URL
    public let output: URL
    public let providerRoot: String
    public let jasnaRunner: String
    public let cancelFile: URL

    public init(
        provider: RestoreProvider,
        input: URL,
        output: URL,
        providerRoot: String,
        jasnaRunner: String,
        cancelFile: URL
    ) {
        self.provider = provider
        self.input = input
        self.output = output
        self.providerRoot = providerRoot
        self.jasnaRunner = jasnaRunner
        self.cancelFile = cancelFile
    }

    public var arguments: [String] {
        var result = [
            "--provider", provider == .local ? "local-lada" : "nvidia-jasna",
            "--input", input.path,
            "--output", output.path,
            "--cancel-file", cancelFile.path
        ]
        if provider == .local {
            result += ["--provider-root", NSString(string: providerRoot).expandingTildeInPath]
        } else {
            result += ["--runner", NSString(string: jasnaRunner).expandingTildeInPath]
        }
        return result
    }
}

public enum ProgressLineParser {
    public static func percent(from line: String) -> Int? {
        guard let token = line.split(separator: " ").first,
              token.hasSuffix("%"),
              let value = Int(token.dropLast()),
              (0...100).contains(value) else {
            return nil
        }
        return value
    }

    public static func friendlyStatus(from line: String) -> String? {
        if line.contains("accepted") || line.contains("validating") { return "Preparing…" }
        if line.contains("starting-provider") { return "Starting restoration…" }
        if line.contains("restoring") { return "Restoring video…" }
        if line.contains("output-validated") { return "Checking output…" }
        if line.contains("completed") { return "Complete" }
        if line.contains("cancelled") { return "Cancelled" }
        return nil
    }
}
