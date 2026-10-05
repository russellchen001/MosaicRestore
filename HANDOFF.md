# MosaicRestore — HANDOFF

## Current Phase
v1.0.0 remains published as a source release and its tag/history must not be deleted or rewritten. Local Computer, Core/Desktop, the P3 long-video production workflow, the Local quality gate, and the Lada/CUDA cloud infrastructure lifecycle are genuinely accepted. The formal Jasna Cloud Compute and Agent Cloud Computer products are not complete.
No cloud resource may be started during this documentation closure. AI-OS is unchanged. Further implementation and paid testing are paused while Codex quota is approximately 17%.

## Authoritative Current Status
- Product definition is locked: Local Computer = Lada/MPS; formal Cloud Compute = headless Jasna/NVIDIA/TensorRT; formal Agent Cloud Computer = GUI Agent → Jasna/NVIDIA/TensorRT.
- Lada/CUDA cloud remains infrastructure validation and an engineering fallback only. It cannot be used as evidence that either formal cloud product is complete.
- AirGPU Windows/T4 historically ran real Jasna v0.10.0 with Lada YOLO v4 detection and BasicVSR++/TensorRT restoration. After cache warm-up, it processed the approximately 60-second P0 sample in 36.25 seconds. This proves the Windows/T4 Jasna runtime can work; it does not accept the current automated product paths.
- RunPod Linux Jasna v0.10.0 portable loaded its engines but stalled at `Processing video: 0%`, with 0% GPU use and no output. Linux Jasna is not the recommended closure path.
- P5 RunPod Linux/Lada CUDA genuinely proved provider contract behavior, visible GUI-agent launch, session reconnect, stable PID/start time and progress continuity, cancellation/process exit, download, SHA-256 and ffprobe. Those results remain authoritative infrastructure evidence only.
- Formal Cloud Compute is blocked because the Jasna Windows headless/automation runner has not completed a real E2E that restores media and verifies download, SHA-256 and ffprobe.
- Formal Agent Cloud Computer is blocked because GUI Agent → Jasna Windows/TensorRT has not completed a real E2E with restore/download/hash/ffprobe plus session reconnect, PID/start-time/progress continuity and cancel/process-exit evidence.
- Therefore it is inaccurate to describe v1.0.0 as having all three product execution paths complete. The release's Local/Core/Desktop/long-video and infrastructure capabilities remain valid; formal Jasna Cloud/Agent Cloud acceptance remains incomplete.

## Why We Are Blocked / Why Previous Attempts Failed
- The earlier status incorrectly promoted Lada/CUDA infrastructure acceptance into cloud product completion. That caused an incorrect completion claim and avoidable Codex usage and cloud cost.
- Recent Windows attempts do not show that Jasna itself is unworkable. They show that preflight and acceptance design were not closed before opening paid windows: remote input and lock-screen behavior, deployment transfer and unattended bootstrap were not fully verified offline.
- Paid-window time was then spent debugging Moonlight/remote interaction and transfer/deployment prerequisites. The critical restore chain never reached actual Jasna processing, so both formal Jasna E2E paths remain incomplete rather than failed runtime validations.
- The user has already spent approximately two days, about US$20 in AirGPU/RunPod-scale cloud cost, and substantial Codex quota. Open-ended experimentation is no longer allowed. With about 17% Codex quota remaining, implementation and paid testing must pause until quota recovers; no paid resource may be started.
- After quota recovery, the shortest path is to reuse the previously successful AirGPU Windows/T4 Jasna environment. First close the headless runner, GUI runner, deployment transfer, remote input/lock-screen/session behavior, evidence collection and one-click acceptance entirely offline. Then use one bounded paid window to complete both real Jasna E2Es.
- The paid acceptance must retain real restored output, download, SHA-256 and ffprobe for both paths; Agent Cloud must additionally retain reconnect, PID/start-time/progress continuity, cancellation and process-exit evidence. Do not return to the RunPod Linux Jasna 0% route and do not substitute Lada/CUDA for the formal cloud backend.

## Product
Local-first AI video mosaic restoration with two product surfaces:
1. Standalone Desktop.
2. Built-in AI-OS capability.
Both share one Mosaic Core.

## Architecture Decisions
- Core does not depend on an LLM.
- Detector, tracker, restorer and compute backend remain replaceable.
- Temporal tracking, scene boundaries and overlap belong in Core.
- Local Apple Silicon baseline: Lada + MPS.
- NVIDIA/cloud product baseline: Jasna v0.10.0 + Lada YOLO v4 detector + BasicVSR++ + TensorRT FP16 on Windows/T4.
- Lada/CUDA cloud execution remains an engineering/infrastructure verifier, not a formal cloud product backend.
- Local and NVIDIA backends share one Core contract but may use different inference implementations.
- Secondary restoration is deferred beyond P1.
- JavPlayer remains a commercial product/quality reference, not a P0 dependency.
- Agent Cloud Computer is a third provider contract, not an AI-OS feature branch: Core owns its lifecycle but delegates desktop control to an external agent adapter.
- The accepted reference transport is an authenticated HTTPS relay to a Windows GUI agent. Task start/cancel must produce GUI action evidence; direct SSH or the P4 cloud runner is rejected as this provider's execution transport.
- Microsoft UFO2/UFO3 (MIT) may replace the reference agent at the adapter boundary. The bundled standalone path uses pywinauto (BSD-3-Clause) for Windows UI Automation and keeps pywinauto, Lada, relay software, credentials, and rented-machine details outside Core/Desktop.

## Execution Providers
1. Local Computer.
2. Cloud Compute — headless Jasna/NVIDIA/TensorRT on a user-funded GPU host.
3. Agent Cloud Computer — GUI agent operates Jasna/NVIDIA on a user-rented GPU desktop.
Cloud compute costs are paid directly by the user.

## P0 Results
- Lada / Apple M4 / MPS: 60.03s video processed in 94.00s (1.57x realtime).
- Jasna / Tesla T4 / RF-DETR v6: 57.86s (0.96x realtime), but real sample showed mosaic detection misses.
- Jasna / Tesla T4 / Lada YOLO v4: 36.25s cached run (0.60x realtime).
- Jasna + Lada detector removed the observed detection misses.
- Visual comparison found Lada/M4 and Jasna+Lada-detector restoration quality broadly comparable on the P0 sample.
- P0 validated both local Apple Silicon and NVIDIA cloud execution.

## P1 Scope
Single-video Mosaic Core MVP:
input → detect → temporal track → restore → overlap/fusion → encode.
No Desktop UI, AI-OS integration, cloud provisioning, custom training, or realtime playback in P1.

## P1 Technical Decision
Mosaic Core is a Rust library. ML implementations and external runtimes remain behind Provider adapters so Desktop and AI-OS can share the same Core contract.
Third-party runtimes execute as child processes; no AGPL Lada source is copied into Core.
The Core runner owns request validation, task state, progress events, cancellation, output validation and provider-neutral error mapping.

## P1 Provider Decision
Mosaic Core exposes a provider-neutral RestorationProvider contract.
Execution providers declare supported compute backends before execution.
Lada, Jasna, MPS, CUDA and TensorRT implementation details remain outside the Core contract.

Local Lada adapter contract:
- External `lada-cli` process.
- Apple MPS backend.
- Lada YOLO v4-fast detector.
- BasicVSR++ v1.2 restorer.

NVIDIA/Jasna adapter contract:
- External runner supplied by path.
- `lada-yolo-v4` detector.
- `basicvsrpp` restorer.
- TensorRT backend.

## P1 Verification
- `verify/verify_p1_mvp.sh` is the complete P1 acceptance entry point.
- 8 Core behavior tests pass, including Local Lada and NVIDIA/Jasna adapter contracts, progress, cancellation and provider failure mapping.
- The CLI runner builds and rejects invalid requests without overwriting an existing output.
- Real end-to-end smoke restore passed through Local Lada on Apple MPS; the restored MP4 was validated with ffprobe.
- NVIDIA/Jasna execution was contract-tested with a fixture runner because this Mac has no NVIDIA runtime. Real NVIDIA infrastructure remains outside P1.
- `benchmark/samples`, `benchmark/results`, `benchmark/lada-upstream` and `core/target` remain untracked and ignored.

## P2 Scope
Native macOS Desktop MVP:
choose one input video → restore → show progress → cancel → reveal completed output.
Provider, detector, restorer and backend details are hidden under Advanced.

## P2 Technical Decision
Desktop is a dependency-free SwiftUI app packaged as `MosaicRestore.app`.
It invokes the existing Rust Mosaic Core executable and consumes the P1 progress/cancellation contract; restoration logic is not duplicated in Swift.
Local Lada on Apple MPS is the default. Cloud/NVIDIA remains an Advanced provider entry that accepts an external provider-neutral cloud configuration and does not block local Desktop use.
The external Lada and Jasna runtimes remain outside the app source; no AGPL upstream source is copied into Desktop or Core.

## P2 Verification
- `verify/verify_p2_desktop.sh` is the complete P2 acceptance entry point.
- The release app bundle builds, is ad-hoc signed, and contains both the SwiftUI executable and Rust Mosaic Core executable.
- Desktop command generation covers Local Lada and Cloud/NVIDIA provider contracts; progress mapping and cancellation behavior pass executable checks.
- The packaged Core completed a real Local Lada/MPS smoke restore and produced a readable MP4.
- The app UI process launch smoke check passed on macOS.
- Real NVIDIA/Jasna execution is SKIP on this Apple Silicon Mac because no NVIDIA runtime is available; the provider boundary remains contract-tested.
- `desktop/.build`, `desktop/build`, Core build output, benchmark samples/results and upstream runtimes remain ignored.

## P3 Scope
Production workflow for videos lasting tens of minutes to hours:
chunk planning and sequential processing → checkpoint/resume → bounded retry → validated assembly → cleanup.
Multiple Desktop selections form one ordered batch with task-level aggregate progress and a safe stop boundary.

## P3 Technical Decision
Long-video lifecycle and queue semantics belong in Rust Mosaic Core so Desktop and future AI-OS integration share the same behavior.
Core uses `ffmpeg`/`ffprobe` for provider-neutral chunking, assembly, readability and duration validation; restoration remains behind the existing Local Lada/MPS and NVIDIA/Jasna provider contract.
Each task has a deterministic workspace and atomically written checkpoint. Success atomically moves the validated output into place and removes task files; cancellation or failure keeps completed chunks for resume.
The queue is sequential and stops safely on the first failed or cancelled task. Each chunk receives one automatic retry by default.
Desktop remains a compact SwiftUI surface: selecting multiple videos creates a queue, while provider/runtime details remain under Advanced.
No AGPL upstream source is copied into Core or Desktop.

## P3 Verification
- `verify/verify_p3_long_video.sh` is the complete P3 acceptance entry point.
- Real short MP4 fixtures exercise a four-chunk plan, cancellation and unexpected process death after one completed chunk, checkpoint resume without repeating completed work, and final readable output with reasonable duration.
- A provider fixture verifies one bounded retry after failure and successful recovery.
- Disk-space preflight rejects an impossible requirement before output creation.
- Successful tasks remove their workspaces; cancelled/failed tasks retain only resumable task state.
- A two-item batch verifies ordered Running/Succeeded terminal states and readable outputs.
- P1, P2 and P3 verification scripts pass together. Real NVIDIA/Jasna remains SKIP on this Apple Silicon Mac when no NVIDIA runtime is available.

## P4 Scope
Provider-neutral user-funded cloud execution:
configuration validation → upload → GPU/driver/CUDA/external-runtime/Lada-detector readiness → estimate → remote start/progress → cancellation/recovery → download → existing P3 output validation.
Desktop keeps Local Lada/MPS as the simple default and exposes the real Cloud/NVIDIA path only under Advanced.

### Jasna cloud product correction — 2026-10-05
- `adapters/http_jasna_cloud_adapter.py` maps the unchanged Core cloud contract to the existing authenticated outbound HTTPS relay; it never provisions or starts a cloud machine.
- The shared Windows service has two distinct launch modes: headless `jasna.exe` for Cloud Compute and existing visible PowerShell/UIA launch for Agent Cloud Computer. Upload, download, session, relay and evidence transport are reused rather than rebuilt.
- Runtime is pinned by `adapters/jasna-airgpu-v0.10.0.json`: Jasna v0.10.0 / commit `93d0584`, Tesla T4, `lada-yolo-v4`, BasicVSR++ v1.2 weights, TensorRT FP16 cache, H.264 CQ 18, max clip 60 and temporal overlap 8. Paid-window engine compilation is forbidden; readiness requires the existing T4 `.engine` cache.
- `adapters/deploy_windows_jasna.cmd` is the single Windows deployment entry. `verify/verify_jasna_airgpu.sh --real ...` runs headless Cloud Compute first and GUI Agent Cloud Computer second, then retains output hashes, ffprobe JSON, logs and evidence ZIPs. The script does not start, stop, purchase or switch cloud resources.
- Offline acceptance passes only tooling/fixture behavior and is not real NVIDIA evidence. Formal Cloud Compute and Agent Cloud Computer remain `NOT RUN` until both complete in one user-approved AirGPU window.
- Final offline bundle: `mosaic-jasna-airgpu-v0.10.0-v3.zip`, 52,588,898 bytes, SHA-256 `9578bdeb232683e1d20b2cc74e3130d5217c5b7ba211dbfe3bfd2c4d83f42030`; it deterministically locates the preserved Jasna runtime, then pins version/models/cache/command. Bundle manifest/dependencies and 11 focused behavior checks pass. No paid instance was started.
- Live cost audit on 2026-10-05: AirGPU machine is `Off`, Tesla T4/Windows Server 2025, displayed rate US$2.10/hour and current credit US$1.01. At the recorded 10% VAT rate, conservative cost is US$2.31/hour and available credit covers about 26.2 billed minutes. Plan: complete useful work and request Stop by minute 12, allow up to 10 minutes for Off, hard billed envelope 22 minutes ≈ US$0.847; minimum extra funding is US$0.00 if these stop gates are honored.
- RunPod audit found all compute stopped. The sole legacy pod still charging US$0.01/hour for container storage (`amateur_fuchsia_puma`) was terminated under the user's stop-all-paid-resources instruction; its non-network volume/data is irrecoverable. Remaining listed pods display US$0.00/hour.

## P4 Technical Decision
Cloud execution uses a versioned external adapter command contract owned by Mosaic Core; Core does not contain AirGPU, RunPod, or another vendor API.
The bundled generic SSH adapter can target AirGPU, RunPod, or a user-owned NVIDIA host through a named profile. Provider credentials and SSH keys remain outside the app and repository, and GPU charges are paid directly by the user.
The remote runner remains external and must provide Lada YOLO v4 detection, BasicVSR++ restoration, a CUDA backend, persistent runtime-cache reuse, job status, and cancellation. `adapters/linux_nvidia_runner.sh` is the bundled runner contract implementation; the official AGPL Lada source and weights are deployed only on the remote host and are not copied into Core or Desktop.
The RunPod runtime is pinned to official Lada commit `20cb34a20a83c72c87a991d2c949032c70085b16`, PyTorch 2.8/CUDA 12.8, device `cuda:0`, v4-fast detector weights, and BasicVSR++ v1.2 restoration weights.
Jasna v0.10.0 Linux portable is not the P4 acceptance dependency: on this RunPod it loaded its TensorRT sub-engines and detector but remained at `Processing video: 0%` with 0% GPU use and no output for both the smoke fixture and a real 60-second video. Its generated TensorRT engine stays external and available for future compatibility work; the accepted runner uses the stable Lada CUDA path and cached model weights.
P3 chunking/checkpoint behavior remains above the provider boundary, so cloud jobs inherit bounded retry, crash resume, batch ordering, final ffprobe validation, and cleanup semantics.

## P4 Verification — infrastructure history
- `verify/verify_p4_cloud_execution.sh` is the P4 acceptance entry point.
- Executable fixture coverage passes for cloud configuration validation, upload/download, complete NVIDIA runtime readiness, exact Lada/CUDA runner arguments, progress, remote cancellation, transient connection recovery, runtime cache hit, cost/time estimate, and output integrity.
- Rust Core has 14 passing behavior tests, including cloud success, readiness rejection, cancellation, and transient status recovery.
- Desktop contract compiles and passes with the Xcode beta toolchain; the Advanced Cloud/NVIDIA path submits `cloud-nvidia` configuration and displays progress plus user-paid cost/time estimates.
- `MOSAIC_CLOUD_CONFIG` real mode passes on an RTX 4090: upload, readiness, estimate, start, status, cached runtime reuse, readable MP4 download, and ffprobe validation all succeed.
- A separate real 60-second baseline run was cancelled after remote start; Core returned `Cancelled`, the remote job state became `cancelled`, no local output was created, and no Lada/Jasna process remained.
- P1, P2, P3, and P4 acceptance scripts pass together. P2's local-machine NVIDIA probe remains an expected `SKIP` on Apple Silicon; P4 is the authoritative real cloud NVIDIA acceptance.
- These Lada/CUDA results remain valid infrastructure validation, but no longer close the formal Jasna Cloud Compute product gate.

## v1.0.0 Release Closure — corrected status
- Release-candidate baseline started from `416a87539a3fb6e90c57c5ffb60c93a909eb286e` with a clean worktree.
- P1–P3, Desktop and the Local Computer quality gate remain accepted. P4/P5 Lada/CUDA evidence is preserved as authoritative infrastructure evidence only; it must not be used to claim the formal Jasna cloud products are complete.
- Rust formatting and Clippy with warnings denied pass; the Swift release build passes.
- Desktop now renders an unavailable cloud price as `Cost unknown` instead of a fake dollar amount, clears stale estimates before a new selection/run, and rejects a whitespace-only cloud configuration before submission.
- `desktop/build/MosaicRestore.app` is an arm64 release app with a valid strict ad-hoc signature. The installed `/Applications/MosaicRestore.app` passes signature verification and launches to its initial usable window.
- Desktop uses one native SwiftUI glass visual system: adaptive Material cards and controls, a single cool accent, consistent rounded geometry, restrained hover/pressed feedback, and solid-surface fallbacks for reduced transparency. The input, Local/Cloud selection, progress, errors, Advanced settings, and actions share these reusable components without changing Core behavior.
- The RC glass baseline uses only public AppKit/SwiftUI APIs: a hidden-titlebar full-size content window, transparent `NSWindow`, and `NSVisualEffectView` with behind-window blending provide real window-level transmission. Reusable glass cards, buttons, and the custom Local/Cloud segmented control add adaptive blur, highlight edges, depth, hover/pressed/disabled/error states, and Reduce Motion/Reduce Transparency fallbacks.
- `verify/verify_glass_ui.sh` performs an actual Release build, validates both bundled executables and the strict app signature, reads bundle metadata, and launches the Desktop process. It passes together with P1–P5 regression, 12 Linux-agent tests, Rust formatting, Clippy with warnings denied, and Swift Release; the installed `/Applications/MosaicRestore.app` was relaunched from a single fresh process and its transparent titlebar, layered cards, and segmented selection states were visually confirmed.
- The complete repository history is published independently at `https://github.com/russellchen001/MosaicRestore` with PUBLIC visibility. Its only remote is this repository's `origin`; no AI-OS remote is configured and history was not rewritten.
- `desktop/build_app.sh` resolves SwiftPM's active release binary directory instead of copying from the legacy `.build/release` path, preventing a stale Desktop executable from being packaged under newer Xcode output layouts.
- This Mac has no Apple Developer signing identity. Developer ID signing, notarization, and Gatekeeper-ready external distribution remain a release blocker outside the repository; local ad-hoc installation is verified.
- Version surfaces are closed at Core `1.0.0` and Desktop `1.0.0` (build `100`). The public GitHub release is source-only unless a properly Developer ID-signed and notarized app is produced later.
- The first P3 verifier invocation hit the known shared-fixture race while its embedded Core tests ran in parallel (`transport=ssh` leaked from another test). Every P3 behavior check still passed; the authoritative `RUST_TEST_THREADS=1` rerun passed P3–P5, 19 Core tests, 12 Linux-agent tests, fmt, Clippy, Swift Release, Desktop launch, strict ad-hoc signature, and glass UI acceptance. No product code was changed to mask the test isolation issue.

## P5 Scope
Agent Cloud Computer execution on a user-rented GPU desktop:
configuration validation → authenticated agent/desktop/GPU/application readiness → session open → upload → GUI-agent launch/action evidence → progress/status → cancellation → same-session reconnect → result download/validation → cost/session metadata → cleanup.
Desktop keeps Local as the default and exposes Agent Cloud Computer as a separate Advanced provider from direct Cloud/NVIDIA.

## P5 Technical Decision
`agent-cloud-computer` uses a versioned external command adapter contract owned by Mosaic Core. Core rejects a direct `ssh` transport and requires `agent-gui`, a non-empty action receipt, positive GUI action count, stable session identity, and a ready result before download.
`adapters/http_agent_cloud_controller.py` is the standalone provider-neutral HTTPS controller. `adapters/windows_gui_agent.py` is the Windows-first reference agent: it receives authenticated file/session requests and uses pywinauto UIA to open a visible PowerShell desktop, paste and launch the configured external restoration command, capture action evidence, report progress, send visible Ctrl-C cancellation, and stream the result back.
The reference agent does not embed Lada or another AGPL runtime. Its application path and command template are external configuration. An outbound HTTPS tunnel or equivalent relay avoids the failed AirGPU NAT/Tailscale/SSH route; provider details and bearer tokens stay outside the repository.
Linux desktop readiness now requires a real VncAuth-authenticated noVNC/WebSocket/RFB framebuffer, VNC socket banner, valid DISPLAY/Xauthority, and running Xfce session/window manager before the agent starts. The same live probe backs Docker health and the agent health contract. Connection files canonically use `vnc_password`; the runner normalizes the earlier `password` field and rejects missing or conflicting credentials before any connection. The existing TigerVNC/noVNC/GUI-agent architecture is retained.

## P5 Verification
### Lada/CUDA infrastructure acceptance — 2026-10-04
- Fixed public image: `ghcr.io/russellchen001/mosaicrestore-p5-linux-desktop:20261004-rfb1`, OCI index `sha256:efc10d5eea8599e5297a06aebf9b6f36e899db7fa285e5056b93a8e2c088ced6`; amd64 child `sha256:a0635dce42adeca070e0082999635898a40ecf6acd270910f45ec2b63320dc93`. Actual anonymous pull was verified during the offline repair; both final real windows use this unchanged runtime.
- Authoritative main chain: `outputs/p5-runpod-long/run` in the current Codex task. Real Xfce/noVNC/RFB + PyAutoGUI launches Lada `cuda:0`; actual RFB and agent transport disconnect/reconnect preserve session/window and Lada PID `1568`, StartTicks `136145308`, with continuous progress. Downloaded H.264 640×360/24fps output is readable, 1800 seconds, 157462478 bytes, SHA-256 `7423b41c04c6804630c00ab72058c5a521be2dd590dfc13bc6bcb884f55a439c`. This synthetic test input proves the execution lifecycle, not a visual-quality review on real mosaics.
- Remaining cancellation ran ONLY after validating the preserved primary report, output hash and reconnect identity evidence. `verify/run_p5_linux.py --cancel-only --primary-evidence ...` uses the repaired 60-second input-upload timeout; control operations retain 10-second bounds. No P4 SSH runner started restoration.
- Cancellation-only evidence: `outputs/p5-cancel-only/run` and `desktop-gate`. RTX 4090 `nl5lb1f156bzzm` authenticated RFB/Xfce in 6.988 seconds, then visible GUI launch produced five actions and receipt `x11-keyboard:p5-cancel-c9019506111740cc9c5fdbab1c51caa5:31457283`. Real Lada PID `1636`, StartTicks `5093719`; after cancellation `cancel_after=[]`, `task_exited=true`, `terminal_exited=true`, `processes=[]`, state `cancelled`. Final report is PASS with `primary_chain=true`, `cancellation=true`, `cancel_only=true`.
- Final live console confirms this pod stopped, compute/container storage Not running, $0.00/hour. Rate was $0.74 GPU + $0.004 ephemeral storage per hour; no separately displayed tax, new persistent storage or top-up. Rounded account balance debit for this window is $0.07 and can include pre-existing account storage; no precise per-pod invoice is claimed.
- Final serial logs: `outputs/final-regression`. P1 contract/provider/MPS MVP, P2 Desktop, P3 production workflow, P4 cloud fixture regression, P5 contract/one-click fixture regression, 12 Linux-agent tests, fmt, Clippy, Swift Release and Desktop acceptance PASS. One-click's optional bundle-dependent unit test is SKIP; true Linux GUI/CUDA acceptance is independently recorded above. Historical attempts below are retained as history, not the current completion status.

### RunPod Linux desktop offline preparation — 2026-10-04
- Core/Desktop remain unchanged in this Linux preparation. `adapters/linux_gui_agent.py` implements the existing external HTTPS/agent-gui contract; Xfce/X11, TigerVNC, noVNC/websockify and PyAutoGUI are external desktop components. Restoration is started by GUI Alt-F2, visible terminal, typed `bash run-visible.sh` and Enter. The script calls external Lada directly; it does NOT invoke P4 SSH adapter/runner.
- Runtime: Lada `20cb34a20a83c72c87a991d2c949032c70085b16`, PyTorch `2.8.0+cu128`, CUDA build `12.8`; model repository revision `bcf461d46d9a98981fc64b815df5178f42215cdf`, v4-fast + BasicVSR++ v1.2 weights with recorded SHA-256. Third-party source/model AGPL notices remain in the external image, not Core. Preserve redistribution obligations before publishing the image.
- Final LOCAL image: `mosaicrestore/p5-linux-desktop:20261004`, amd64, digest `sha256:f3af2aaa3bc17db30c09726589c3f3891b828108a5da37718ece83f1fda01f41`, Docker-reported size 5,199,129,081 bytes. Built successfully; NOT uploaded to a registry. Do not mistake this local tag for an anonymously pullable deployment image.
- `bash verify/verify_p5_linux_desktop.sh --local-desktop <absolute-new-evidence-directory>` ran actual local container Xfce/noVNC, GUI-driven real Lada CPU (not a restoration fixture), same desktop/window/wrapper AND actual Lada Python PID + StartTicks continuity, real RFB disconnect/reconnect and separate agent socket reset, progress to 100%, downloaded MP4, SHA-256, ffprobe, then GUI cancellation and both task/terminal exit. The final evidence is `outputs/p5-linux-local-desktop-ready/run` in the current Codex task. `fixture=false`, `local_cpu=true`; local CUDA availability is FALSE.
- Viewer is preconnected before launching Core/GUI restoration, avoiding a fast-GPU race where the job finishes before the viewer opens. Wrong-session rejection without focus mutation, persisted restoration-PID start-time mismatch, and progress regression were verified by fault injection during a real task. Actual kernel PID recycling was NOT forced; do not claim it was.
- 8 Linux behavior tests PASS; P1–P5 serial local regression PASS, including Swift Release/Desktop contract and packaged real Local Lada/MPS restoration. Rust fmt/Clippy and diff check PASS. Initial parallel Core tests failed with truncated temporary adapter scripts; serial rerun passes. Existing test-fixture concurrency remains a separate issue; no Core code was changed to mask it.
- One-click real entry: `bash verify/verify_p5_linux_desktop.sh --real --connection <owner-only-json> --output <new-evidence-directory> --minutes 20`. Connection contains authenticated HTTPS agent/desktop URLs, token, VNC password and expiry; no start/create/purchase call exists in this entry. It exercises real Core `agent-cloud-computer`, NOT P4. Platform Stop/billing evidence must still be collected separately; runner does not claim to stop billing.
- NOT ready to start a billed RunPod: registry publication + anonymous pull check, fresh balance/rate/storage/tax and at-most-two-attempt budget confirmation are still required. NVIDIA device/model CUDA execution and RunPod HTTP/noVNC proxy behavior are real-window gates, not proven by local CPU acceptance. No RunPod creation/start, top-up, fee, commit or push occurred during this preparation; all local test containers stopped.
- Approved proposed window: 0–10 image/desktop/GPU readiness; 10–15 upload/GUI launch; 15–30 restore+same-session reconnect; 30–40 download/hash/ffprobe; 40–45 cancellation only after primary PASS; Stop by 50; 50–60 stopped/billing evidence and buffer. Each missed deadline or need for现场调试 immediately ends testing and requests Stop. Effective rate incl. storage/tax must fit US$2 per attempt, US$4 total for at most two attempts; no refill.

### RunPod Linux desktop paid acceptance — 2026-10-04
- Published the existing image without rebuilding as `ghcr.io/russellchen001/mosaicrestore-p5-linux-desktop:20261004`; it is Public. Anonymous `linux/amd64` pull returned OCI manifest digest `sha256:f3af2aaa3bc17db30c09726589c3f3891b828108a5da37718ece83f1fda01f41`, identical to the source manifest identity.
- RunPod preflight: balance US$8.24, RTX 4090 US$0.74/hour plus 30 GB ephemeral container disk at US$0.004/hour, no new persistent volume and no top-up. The first pod `7a5t7g3ykekcbv` and migrated second pod `35qksk41sboptg` are both stopped at US$0.00/hour compute/disk; observed ending balance US$8.03, a US$0.21 balance delta during this run. The pre-existing stopped 50 GB volume remains at its prior storage-only charge.
- Attempt 1 stopped before workload launch after the RunPod HTTPS proxy rejected Python urllib's default client signature with HTTP 403 / error 1010. The provider-neutral clients now send `User-Agent: MosaicRestore-P5/1.0`; live health authentication then returned HTTP 200 `status=ready`.
- Attempt 2 proved the public agent endpoint, authenticated health, public noVNC HTML, and agent session open. The independent Playwright/noVNC helper did not receive an RFB `connect` event within 15 seconds, so the verifier stopped before Core upload, GUI launch, CUDA/Lada restoration, reconnect continuity, download, ffprobe, and cancellation acceptance. Evidence is in the Codex output directory `p5-runpod-20261004-attempt2c`; result is FAIL, not a partial P5 pass.
- Both paid instances were stopped immediately on their terminal failure. Temporary bearer/VNC credentials and the owner-only connection file were removed. Do not start a third paid attempt without a new explicit budget authorization and an offline fix or diagnostic for RunPod proxied `/websockify` RFB connection establishment.

### Offline RFB root-cause fix — 2026-10-04
- The previous RFB timeout was not evidence of an unstable VNC server: the real-window connection JSON used `password`, but the JavaScript RFB constructor consumed `vnc_password`. With the original image and its unchanged ENTRYPOINT, the correct credential authenticated and received a 1280×800 framebuffer in 3.46 seconds; a wrong credential produced `Authentication failure`. Local validation cannot prove that the next RunPod proxy connection will pass, so remote RFB remains the first required gate.
- VNC audit: Xtigervnc listens on loopback port 5901, uses `VncAuth`, DISPLAY `:1`, and `/root/.Xauthority`; Xfce session and xfwm4 run. The relay now explicitly listens on `0.0.0.0:6080` and targets `127.0.0.1:5901`, removing hostname/IPv6 ambiguity. Agent port 8765 is started only after the startup probe succeeds; readiness retries are bounded, with diagnostic logs retained.
- `verify/verify_p5_rfb.sh` verifies three independent cold starts, an independent browser container connecting through the Docker-published HTTP/WebSocket port, rejection of wrong credentials/invalid Xauthority/unavailable DISPLAY, and fail-closed readiness after relay/VNC loss. Full local actual Lada CPU GUI main chain, real same-session RFB reconnect, output/hash/ffprobe, and cancellation/process exit also pass. Eleven focused behavior tests pass. NVIDIA CUDA and RunPod proxy acceptance remain NOT RUN in this offline repair.
- Fixed image: `ghcr.io/russellchen001/mosaicrestore-p5-linux-desktop:20261004-rfb1`; OCI index digest `sha256:efc10d5eea8599e5297a06aebf9b6f36e899db7fa285e5056b93a8e2c088ced6`, amd64 child manifest `sha256:a0635dce42adeca070e0082999635898a40ecf6acd270910f45ec2b63320dc93`. Anonymous amd64 pull through an empty Docker credential configuration returned the identical index digest. The original `20261004` image is preserved. This publication is repair tooling, not P5 completion or a new product release.
- Evidence and next-window plan: current Codex task outputs `p5-rfb-pulled-image`, `p5-rfb-final-image`, `p5-rfb-pulled-local-lada/run`, and `P5-RFB-RESULT.md`. Both the RFB failure-injection suite and full local Lada CPU GUI acceptance passed using the anonymously pulled fixed digest. No RunPod start, paid resource, repository commit, or git push occurred during the offline repair.

- `verify/verify_p5_agent_cloud_computer.sh` is the P5 acceptance entry point.
- Core has 19 passing behavior tests. P5 fixture behavior passes configuration, session open, readiness, upload, GUI launch evidence, status/progress, same-session reconnect, cancellation, download, structured error mapping, metadata, cleanup, and explicit direct-SSH bypass rejection.
- The Desktop contract and full Swift release app build pass with three provider choices; Local remains the default.
- P1–P5 regression passes. P4 real NVIDIA is not rerun because RunPod is stopped; its prior RTX 4090 acceptance remains authoritative.
- This Linux/RunPod result accepts GUI-agent infrastructure only. It is not formal Agent Cloud Computer product acceptance because the launched runtime was Lada/CUDA rather than Jasna/NVIDIA. The formal Windows/T4 Jasna GUI E2E remains `NOT RUN`.

## P5 Real E2E Plan — Existing AirGPU Credit
- Initial console view on 2026-10-04 showed existing `airgpu-35d4bba7ac`, Sydney, Tesla T4, Windows Server 2025, 100 GB SSD, Off, credit US$10.00, displayed rate US$2.10/hour. This balance proved stale: a full refresh during the authorized startup showed US$1.27. Account records separately show a 10% VAT rate. Do not use the original US$10.00 view or untaxed 60-minute estimate to authorize another run.
- Reuse the existing Moonlight/desktop access to bootstrap the GUI agent in the interactive Windows session. Use an outbound free HTTPS Quick Tunnel with a bearer-authenticated local agent endpoint. This avoids inbound SSH, port forwarding, and Tailscale. Quick Tunnels are a temporary test transport with no uptime guarantee, not production availability evidence.
- Formal control path: Mosaic Core → HTTP controller → HTTPS relay → Windows UIA agent → visible PowerShell → external Jasna/NVIDIA/TensorRT command. Launch and cancellation must be observed through GUI evidence. Earlier Lada/CUDA planning and evidence in this section are infrastructure history only; do not use the P4 SSH runner or Lada/CUDA to substitute for formal Agent Cloud acceptance.
- Pre-start checks: re-read current price and credit; confirm no new storage or other paid add-ons, hourly billing units, usable desktop access, and a verified stop route. If the projected total exceeds US$2.10 or remaining credit is insufficient, do not start.
- User-approved maximum incremental compute spend remains US$2.10 including any tax, with zero new payment/top-up. The original 45-minute work plus 15-minute shutdown plan is withdrawn: at US$2.10/hour plus 10% VAT it would exceed the cap. Any future attempt must first refresh both dashboard and account balance, verify final taxed billing, and set a shorter hard deadline that fits the actual existing credit with a shutdown reserve. Existing storage charges continue independently and are not new test resources.
- Stop conditions: no usable desktop within 10 minutes; no agent/relay/runtime readiness within 20 minutes; no GUI receipt or restoration progress within 5 minutes after task launch; one reconnect attempt cannot recover the same job within 2 minutes; runtime installation/model download cannot fit the remaining budget; wrong compute backend, missing GUI evidence, invalid output, unsuccessful cancellation, or any need for new payment. End useful work at 45 minutes and prioritize confirmed platform Off before 60 minutes.
- Acceptance evidence: use a small synthetic video; keep launch/cancel screenshots and job/session IDs locally before remote cleanup; verify input/output hash and ffprobe, process termination after GUI cancellation, no surviving restoration child processes, and same-job progress after a real controller/network disconnect. An adapter's self-reported transport/action count alone is insufficient evidence.
- Offline preparation now adds desktop readiness screenshots, same-process reconnect screenshots after an actual HTTP connection drop, GUI cancellation with parent/child exit checks, and authenticated evidence archives retained before job cleanup. These checks have only been exercised with local fixtures, not a real Windows desktop. CUDA restoration correctness and GUI automation compatibility remain real-acceptance gates. The reported `billed_cost_usd` is still calculated from configured hourly rate and is not a provider invoice.
- RunPod is a conditional fallback only if AirGPU cannot support the GUI/agent path. Audit the existing account/retained pod without starting resources, then provide a separate concrete plan and current fee cap. No automatic platform switch or second paid attempt.

### AirGPU attempt on 2026-10-04 — stopped before workload
- The user explicitly approved the existing-machine attempt under the US$2.10 cap and stop conditions. Start was requested approximately 03:18:10 UTC. A full dashboard refresh during Starting revealed only US$1.27, so the insufficient-credit condition ended acceptance immediately. No GUI agent deployment, video upload, restoration launch, or SSH fallback occurred.
- During Starting the platform exposed no enabled Stop control; the card menu only exposed disabled Configure/Delete. At the first observed Running state, Stop was clicked approximately 03:21:30 UTC. The platform subsequently showed Stopping, then Backing up, then confirmed Off by 03:30:30 UTC. The account transaction for this attempt shows 0h 00m and US$0.00 including VAT; remaining balance is US$1.27. The historical balance difference is not this attempt's fee and its full reconciliation is not established.
- P5 real GUI launch, session reconnect, cancellation/process exit, output download, and ffprobe acceptance remain NOT RUN. This is a budget/preflight interruption, not evidence that AirGPU cannot support the GUI path. Existing local P5 implementation and prior P1–P5 regression results remain preserved. No top-up, new paid resource, RunPod switch, AI-OS change, commit, or push occurred in this attempt.

### P5 one-click offline preparation — 2026-10-04
- Technical decision: keep Core/Desktop/provider contract unchanged. Add only deployment and acceptance tooling around the existing standalone HTTP/UIA agent. Read-only Windows CIM process inventory verifies GUI-triggered process exit; it never launches restoration and is not an SSH substitute.
- `verify/prepare_p5_bundle.py --output <new.zip>` builds the offline Windows bundle with official cloudflared 2026.9.3 (release SHA-256 verified), pywinauto 0.6.9, Pillow 11.3.0, pywin32 311, comtypes 1.4.11 and dependency/license files for CPython 3.11/3.12 x64. No GPU model or third-party restoration source is redistributed. Existing Python, external Lada/CUDA application, weights and ffprobe remain prerequisites; missing prerequisites fail rather than silently downloading/installing a runtime in the paid window.
- `adapters/deploy_windows_agent.cmd` invokes the bounded PowerShell deployment; optional arguments specify verified external application/ffprobe paths and command template without editing code. Deployment creates an isolated environment, uses only bundled wheels, creates a bearer-authenticated loopback agent/free outbound relay, and writes an owner-only connection file with an expiry. Token contents must not be pasted into chat or committed. Deadline/failure stops agent/relay, NOT provider billing: AirGPU console Stop and verified Off remain mandatory.
- `bash verify/verify_p5_oneclick.sh --offline` runs narrow fixture behavior tests. With `MOSAIC_P5_BUNDLE=<zip>`, all 7 tests pass, including actual localhost connection teardown, stable-session reconnect, rejection of surviving cancellation children, evidence retained after cleanup, bundle content/checksum/license checks and UTF-16 PowerShell progress parsing. Existing `verify/verify_p5_agent_cloud_computer.sh` also passes: 19 Rust tests, adapter/CLI fixtures and Desktop contract; real GUI remains explicitly SKIP. PowerShell/Windows deployment execution is NOT RUN on macOS; do not describe it as real deployment PASS.
- `bash verify/verify_p5_oneclick.sh --real --connection <secret.json> --output <new-evidence-directory> --minutes 6 --cancel-if-time` is the future acceptance entry point, now success-first. The real Core `agent-cloud-computer` provider forwards through the acceptance-only `verify/p5_success_adapter.py` to the unchanged production HTTP adapter. At the normal download action, the gate first requires actual restoration success, deliberately drops an authenticated connection, reconnects the same completed GUI/session and saves PNG evidence, then permits the real result download. Core performs its existing cleanup; the runner verifies SHA-256 and ffprobe before any optional cancellation. No synthetic success state or SSH runner is substituted. Primary work is limited to four minutes (30 seconds reserved for final artifact checks); cancellation is enabled only after primary PASS and with at least 120 seconds of runner time remaining. Optional failure preserves the primary PASS evidence but still produces overall FAIL/stop instruction. It never starts or switches cloud resources.
- Budget remains a separate human-approved preflight using refreshed balance, tax and elapsed machine time. The deployment's 25-minute default is only an agent lifetime ceiling, not authorization to spend, not a replacement for provider shutdown, and not a new approved test plan. Do not auto-start AirGPU after offline preparation.

### New AirGPU window preflight — 2026-10-04
- User authorized a 20-minute target / 25-minute hard window, primary success chain before optional cancellation, stop tests at 23 minutes, and confirmed Off before 25 minutes. No top-up, platform switch, new dependency downloads or on-the-fly redesign are permitted.
- Full dashboard/account refresh at approximately 03:45 UTC confirms balance US$1.27, displayed rate US$2.10/hour, VAT 10%, existing machine Off. At the conservative taxed rate US$2.31/hour, 25 minutes would cost approximately US$0.9625; pricing/balance assumptions match. No Start was clicked; no incremental compute cost incurred.
- Startup is withheld under the timeout-risk stop rule: the prepared runner still prioritizes cancellation before completion, contrary to the latest user priority, and the existing 51 MB deployment bundle has no verified first-transfer path into the Windows desktop. Mac has no `cloudflared` on PATH; do not silently download a new local relay or improvise a paid-window transfer. The offline preparation was incomplete for unattended bootstrap, despite passing fixture/package checks.
- Before another startup, offline work must establish the already-built bundle transfer route and narrowly reorder acceptance to GUI launch → actual restore → live session reconnect → download → ffprobe, with cancellation optional only after the primary chain. Reuse the current ZIP; no dependency re-download or broad refactor. Prior Stop → Off took about 9 minutes, so reserve at least 10 minutes and request Stop no later than minute 15 for a 25-minute Off deadline; the user's minute-23 latest stop must not be treated as a safe shutdown start time.

### Offline bootstrap/order gaps resolved — 2026-10-04
- User authorized publishing the existing credential-free ZIP as temporary deployment tooling in the existing public MosaicRestore repository. Prerelease `p5-deploy-offline-20261004` is explicitly NOT a product release or P5 acceptance claim. Its tag points at baseline `f6efe84cc38f809b2af133e84457d80b5b3d32a1`; no existing branch/history was rewritten. The unchanged ZIP SHA-256 is `17d40b6dac3a917ed8c7d045c42aaab0f06b1283bc27503547cb528de1cc693b`.
- First transfer uses the anonymous HTTPS prerelease attachment, not Mac cloudflared, SSH, Tailscale, or a new platform. `verify/receive-p5.ps1` is the small credential-free receiver attachment: curl download capped at 60 seconds/no retries, ZIP SHA-256 verification, isolated destination, unzip job capped at 30 seconds, required-file checks, explicit FAIL/Stop instruction. A short bootstrap command fetches this receiver within 15 seconds and verifies receiver SHA-256 `86c7641ca73ed87aeb32f24ec79a909ef086bbd550cf15f0cbe66c5169dd92fe` before running it. It does not start the agent, install missing runtimes, or start any machine.
- Anonymous Mac-side transfer tests: original ZIP HTTP 200, 52,586,786 bytes in 6.540155 seconds with matching SHA-256; receiver HTTP 200, 2,005 bytes in 0.739440 seconds with matching SHA-256. This proves accessible hosting/no GitHub login requirement and package integrity, NOT AirGPU-to-GitHub speed, Windows curl availability, PowerShell execution, or Moonlight typing compatibility. Those remain bounded real-window gates; no indefinite retry is allowed.
- Success-first preparation passes 9/9 offline fixture tests, including the gate requiring succeeded before actual transport reset/reconnect/download and the runner preserving primary success while skipping cancellation if fewer than 120 seconds remain. The existing ZIP and dependencies were not rebuilt/redownloaded separately; only the hosted copies were fetched to test the first-transfer route. Core/Desktop/provider production code is unchanged in this correction.
- Minute plan measured conservatively from clicking Start (not later Running): 0–3 startup/Moonlight/desktop; 3–5 bootstrap download, verified ZIP transfer and unpack; 5–7 offline-wheel deployment/runtime readiness; 7–11 primary GUI restoration → completed-session reconnect → download/hash/ffprobe; 11–13 optional cancellation only after primary PASS and enough time; 13–15 evidence collection and platform Stop; 15–25 shutdown/backup/Off confirmation and exception buffer. Each missed stage deadline triggers immediate Stop as soon as the platform enables it; do not wait for another stage, minute 20, or minute 23. Start shutdown earlier whenever work ends early. Stop→Off latency is provider-controlled; the 10-minute reserve is based on the last observation, not a guaranteed platform SLA.
- No AirGPU startup/charge, top-up, other platform, new dependency installation or real GUI acceptance occurred in this offline correction. Windows receiver/deployment execution remains NOT RUN; PowerShell is unavailable on this Mac. Report the bounded transfer preparation honestly rather than calling the Windows transfer real PASS.

## AI-OS Integration Boundary
- AI-OS must call the same Mosaic Core library or CLI contract used by Desktop: `RestoreRequest`, provider-neutral `RestorationProvider`, `ProgressUpdate`, `CancellationToken`, `RestoreErrorKind`, and the P3 production workflow.
- AI-OS must supply external runtime or cloud configuration at the adapter boundary. Vendor credentials, SSH keys, RunPod APIs, Lada source, and Jasna source must not enter Core or AI-OS persistence.
- No AI-OS-specific adapter or vendor branch is added. MosaicRestore itself owns and accepts all three execution-provider lifecycles, including Agent Cloud Computer. Only AI-OS host wiring to the stable Mosaic Core/CLI contract and its host-level end-to-end acceptance are deferred to AI-OS v2.0.

## Final Long-Video Quality Acceptance — PASS (2026-10-05)
- The selected real sample stayed outside git. Input: H.264/AAC, 1280×720, 29.97 fps, 4,224.253 seconds, 2,116,790,232 bytes, 126,600 video frames, SHA-256 `6f88975ec5e1bab8437d50d60ccd3d8b87f44e0f6edb6781cc348231b106464c`.
- The existing production path ran locally with external Lada/MPS to avoid unnecessary cloud cost: 15 deterministic 300-second chunks, durable checkpoint updates after every completed chunk, zero retries, validated assembly, terminal `PASS restore`, and successful workspace cleanup. Existing P3 interruption/process-death tests remain the authoritative resume evidence; this uninterrupted quality run did not manufacture a failure.
- Output: H.264/AAC, 1280×720, 29.97 fps, 4,224.736 seconds, 1,260,324,533 bytes, 126,600 video frames, SHA-256 `483f852ad75bbd869d053cbdf1802a908f0c090790113d2bd6b515d1fc382932`. Duration delta is +0.483 seconds.
- Full audio/video decode passes. Video and audio DTS are monotonic; frame seek succeeds around every 300-second chunk boundary. Freeze detection reports the same three source events in input and output, so the workflow introduced no new freeze event.
- Visual review covered 15 full-duration sample points, targeted high-change frames, and a consecutive restored sequence. Sampled mosaics were replaced consistently with no obvious missed target, timing jump, flicker, or severe artifact. This is a bounded release-quality review, not a claim that AI reconstruction recovers factual hidden pixels.
- RunPod was not started for this gate. Incremental RunPod cost is US$0.00; the previously accepted P5 instances remain recorded as stopped at US$0.00/hour.

## Remaining Release Blockers
- Formal Cloud Compute remains blocked on a real Windows/NVIDIA/Jasna headless E2E with restore, download, SHA-256 and ffprobe evidence.
- Formal Agent Cloud Computer remains blocked on a real GUI Agent → Windows/NVIDIA/Jasna E2E with restore/download/hash/ffprobe, reconnect continuity, PID/start-time/progress continuity, cancellation and process-exit evidence.
- These are MosaicRestore-side product blockers. They are not closed by the accepted Linux/Lada CUDA infrastructure lifecycle and must be completed before AI-OS v2.0 host wiring can treat all three providers as accepted.
- The existing source release remains published; do not delete its tag or rewrite history. External app distribution separately requires a valid Apple Developer signing identity and notarization, and the current app must not be presented as a formally distributed macOS build.
- The AI-OS repository was not modified.
