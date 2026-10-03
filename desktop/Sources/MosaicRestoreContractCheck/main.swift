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
    jasnaRunner: "",
    cancelFile: URL(fileURLWithPath: "/tmp/cancel")
)
check(local.arguments == [
    "--provider", "local-lada",
    "--input", "/tmp/input video.mp4",
    "--output", "/tmp/output video.mp4",
    "--cancel-file", "/tmp/cancel",
    "--provider-root", "/tmp/lada"
], "Local desktop command uses the Mosaic Core contract")

let cloud = RestoreCommand(
    provider: .nvidia,
    input: URL(fileURLWithPath: "/tmp/input.mp4"),
    output: URL(fileURLWithPath: "/tmp/output.mp4"),
    providerRoot: "",
    jasnaRunner: "/tmp/jasna-runner",
    cancelFile: URL(fileURLWithPath: "/tmp/cancel")
)
check(cloud.arguments.contains("nvidia-jasna"), "Cloud NVIDIA provider entry remains available")
check(Array(cloud.arguments.suffix(2)) == ["--runner", "/tmp/jasna-runner"],
      "Cloud runner path reaches Mosaic Core")
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
