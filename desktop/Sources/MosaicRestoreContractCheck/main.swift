import DesktopSupport
import Foundation

var failures = 0

@MainActor
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("✓ \(name)")
    } else {
        print("✗ \(name)")
        failures += 1
    }
}

let local = RestoreCommand(
    provider: .local,
    input: URL(fileURLWithPath: "/tmp/input video.mp4"),
    output: URL(fileURLWithPath: "/tmp/output video.mp4"),
    providerRoot: "/tmp/lada",
    cloudConfig: "",
    cancelFile: URL(fileURLWithPath: "/tmp/cancel")
)
check(local.arguments == [
    "--provider", "local-lada",
    "--production",
    "--chunk-seconds", "300",
    "--max-retries", "1",
    "--cancel-file", "/tmp/cancel",
    "--input", "/tmp/input video.mp4",
    "--output", "/tmp/output video.mp4",
    "--provider-root", "/tmp/lada"
], "Local desktop command uses the Mosaic Core contract")

let batch = RestoreCommand(
    provider: .local,
    inputs: [URL(fileURLWithPath: "/tmp/a.mp4"), URL(fileURLWithPath: "/tmp/b.mp4")],
    outputs: [URL(fileURLWithPath: "/tmp/a.restored.mp4"), URL(fileURLWithPath: "/tmp/b.restored.mp4")],
    providerRoot: "/tmp/lada",
    cloudConfig: "",
    cancelFile: URL(fileURLWithPath: "/tmp/cancel")
)
check(batch.arguments.filter { $0 == "--input" }.count == 2 &&
      batch.arguments.filter { $0 == "--output" }.count == 2,
      "Desktop submits an ordered production queue")

let cloud = RestoreCommand(
    provider: .nvidia,
    input: URL(fileURLWithPath: "/tmp/input.mp4"),
    output: URL(fileURLWithPath: "/tmp/output.mp4"),
    providerRoot: "",
    cloudConfig: "/tmp/cloud.conf",
    cancelFile: URL(fileURLWithPath: "/tmp/cancel")
)
check(cloud.arguments.contains("cloud-nvidia"), "Cloud NVIDIA provider entry is live")
check(Array(cloud.arguments.suffix(2)) == ["--cloud-config", "/tmp/cloud.conf"],
      "Cloud configuration reaches Mosaic Core")
check(ProgressLineParser.cloudEstimate(from: "CLOUD estimated_seconds=120 estimated_cost_usd=0.42") ==
      "Estimated 120s · $0.42 USD paid to your cloud provider",
      "Desktop shows cloud time and user-paid cost estimate")
check(ProgressLineParser.percent(from: "15% Running restoring") == 15,
      "Desktop reads Core progress")
check(ProgressLineParser.friendlyStatus(from: "100% Succeeded completed") == "Complete",
      "Desktop maps Core completion state")
check(ProgressLineParser.percent(from: "not progress") == nil,
      "Desktop ignores unrelated provider output")

if failures == 0 {
    print("PASS P2 Desktop contract")
    exit(0)
}
print("FAIL P2 Desktop contract — \(failures) check(s) failed")
exit(1)
