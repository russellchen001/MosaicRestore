import Foundation

public enum RestoreProvider: String, CaseIterable, Identifiable {
    case local = "Local (Apple Silicon)"
    case agentCloud = "Agent Cloud Computer"
    case nvidia = "Cloud / NVIDIA"

    public var id: String { rawValue }
}

public struct RestoreCommand {
    public let provider: RestoreProvider
    public let inputs: [URL]
    public let outputs: [URL]
    public let providerRoot: String
    public let cloudConfig: String
    public let agentCloudConfig: String
    public let cancelFile: URL

    public init(
        provider: RestoreProvider,
        input: URL,
        output: URL,
        providerRoot: String,
        cloudConfig: String,
        agentCloudConfig: String = "",
        cancelFile: URL
    ) {
        self.provider = provider
        self.inputs = [input]
        self.outputs = [output]
        self.providerRoot = providerRoot
        self.cloudConfig = cloudConfig
        self.agentCloudConfig = agentCloudConfig
        self.cancelFile = cancelFile
    }

    public init(
        provider: RestoreProvider,
        inputs: [URL],
        outputs: [URL],
        providerRoot: String,
        cloudConfig: String,
        agentCloudConfig: String = "",
        cancelFile: URL
    ) {
        self.provider = provider
        self.inputs = inputs
        self.outputs = outputs
        self.providerRoot = providerRoot
        self.cloudConfig = cloudConfig
        self.agentCloudConfig = agentCloudConfig
        self.cancelFile = cancelFile
    }

    public var arguments: [String] {
        let providerName: String
        switch provider {
        case .local: providerName = "local-lada"
        case .agentCloud: providerName = "agent-cloud-computer"
        case .nvidia: providerName = "cloud-nvidia"
        }
        var result = [
            "--provider", providerName,
            "--production",
            "--chunk-seconds", "300",
            "--max-retries", "1",
            "--cancel-file", cancelFile.path
        ]
        for (input, output) in zip(inputs, outputs) {
            result += ["--input", input.path, "--output", output.path]
        }
        switch provider {
        case .local:
            result += ["--provider-root", NSString(string: providerRoot).expandingTildeInPath]
        case .agentCloud:
            result += ["--agent-cloud-config", NSString(string: agentCloudConfig).expandingTildeInPath]
        case .nvidia:
            result += ["--cloud-config", NSString(string: cloudConfig).expandingTildeInPath]
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
        if line.contains("validating-agent-cloud-config") { return "Checking agent cloud configuration…" }
        if line.contains("agent-session-opening") { return "Opening remote desktop session…" }
        if line.contains("agent-desktop-readiness") { return "Checking desktop agent and GPU…" }
        if line.contains("agent-uploading") { return "Uploading video to agent computer…" }
        if line.contains("agent-gui-launching") { return "Starting through the desktop agent…" }
        if line.contains("agent-gui-started") { return "Desktop agent started restoration…" }
        if line.contains("agent-gui-progress") { return "Restoring on the agent computer…" }
        if line.contains("agent-session-reconnecting") { return "Reconnecting to the agent session…" }
        if line.contains("agent-downloading") { return "Downloading agent result…" }
        if line.contains("agent-output-validated") { return "Checking agent output…" }
        if line.contains("accepted") || line.contains("validating") { return "Preparing…" }
        if line.contains("starting-provider") { return "Starting restoration…" }
        if line.contains("restoring") { return "Restoring video…" }
        if line.contains("checkpoint-resumed") { return "Resuming previous work…" }
        if line.contains("validating-cloud-config") { return "Checking cloud configuration…" }
        if line.contains("uploading") { return "Uploading video…" }
        if line.contains("gpu-runtime-readiness") { return "Checking NVIDIA runtime…" }
        if line.contains("remote-runner-started") { return "Cloud restoration started…" }
        if line.contains("remote-progress") { return "Restoring in cloud…" }
        if line.contains("recovering-connection") { return "Reconnecting to cloud…" }
        if line.contains("downloading") { return "Downloading result…" }
        if line.contains("chunk-completed") { return "Restoring video…" }
        if line.contains("output-validated") { return "Checking output…" }
        if line.contains("completed") { return "Complete" }
        if line.contains("cancelled") { return "Cancelled" }
        return nil
    }

    public static func cloudEstimate(from line: String) -> String? {
        let isAgentCloud = line.hasPrefix("AGENT_CLOUD ")
        guard line.hasPrefix("CLOUD ") || isAgentCloud else { return nil }
        let pairs: [(String, String)] = line.split(separator: " ").dropFirst().compactMap { token in
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
        let values = Dictionary(uniqueKeysWithValues: pairs)
        guard let seconds = values["estimated_seconds"], let cost = values["estimated_cost_usd"] else { return nil }
        if cost == "unknown" {
            return isAgentCloud
                ? "Estimated \(seconds)s · Agent computer cost unknown"
                : "Estimated \(seconds)s · Cost unknown (paid to your cloud provider)"
        }
        return isAgentCloud
            ? "Estimated \(seconds)s · $\(cost) USD for the agent computer"
            : "Estimated \(seconds)s · $\(cost) USD paid to your cloud provider"
    }
}
