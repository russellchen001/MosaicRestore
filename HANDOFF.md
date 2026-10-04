# MosaicRestore — HANDOFF

## Current Phase
Release Candidate closure on 2026-10-04. P1–P4 are complete.
The provider-neutral SSH lifecycle and a real RunPod RTX 4090 Lada/CUDA end-to-end run both pass, including real cancellation and readable output download.
The final long-video cloud run is prepared but intentionally deferred; RunPod remains stopped.

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
- NVIDIA/cloud baseline: external runner + Lada YOLO v4 detector + BasicVSR++ on CUDA; Jasna remains an optional compatible runtime, not a required dependency.
- Local and NVIDIA backends share one Core contract but may use different inference implementations.
- Secondary restoration is deferred beyond P1.
- JavPlayer remains a commercial product/quality reference, not a P0 dependency.

## Execution Providers
1. Local Computer.
2. Agent Cloud Computer — AI operates software on a user-rented GPU desktop.
3. Cloud Compute — user-owned BYOC/BYOK GPU provider.
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

## P4 Technical Decision
Cloud execution uses a versioned external adapter command contract owned by Mosaic Core; Core does not contain AirGPU, RunPod, or another vendor API.
The bundled generic SSH adapter can target AirGPU, RunPod, or a user-owned NVIDIA host through a named profile. Provider credentials and SSH keys remain outside the app and repository, and GPU charges are paid directly by the user.
The remote runner remains external and must provide Lada YOLO v4 detection, BasicVSR++ restoration, a CUDA backend, persistent runtime-cache reuse, job status, and cancellation. `adapters/linux_nvidia_runner.sh` is the bundled runner contract implementation; the official AGPL Lada source and weights are deployed only on the remote host and are not copied into Core or Desktop.
The RunPod runtime is pinned to official Lada commit `20cb34a20a83c72c87a991d2c949032c70085b16`, PyTorch 2.8/CUDA 12.8, device `cuda:0`, v4-fast detector weights, and BasicVSR++ v1.2 restoration weights.
Jasna v0.10.0 Linux portable is not the P4 acceptance dependency: on this RunPod it loaded its TensorRT sub-engines and detector but remained at `Processing video: 0%` with 0% GPU use and no output for both the smoke fixture and a real 60-second video. Its generated TensorRT engine stays external and available for future compatibility work; the accepted runner uses the stable Lada CUDA path and cached model weights.
P3 chunking/checkpoint behavior remains above the provider boundary, so cloud jobs inherit bounded retry, crash resume, batch ordering, final ffprobe validation, and cleanup semantics.

## P4 Verification
- `verify/verify_p4_cloud_execution.sh` is the P4 acceptance entry point.
- Executable fixture coverage passes for cloud configuration validation, upload/download, complete NVIDIA runtime readiness, exact Lada/CUDA runner arguments, progress, remote cancellation, transient connection recovery, runtime cache hit, cost/time estimate, and output integrity.
- Rust Core has 14 passing behavior tests, including cloud success, readiness rejection, cancellation, and transient status recovery.
- Desktop contract compiles and passes with the Xcode beta toolchain; the Advanced Cloud/NVIDIA path submits `cloud-nvidia` configuration and displays progress plus user-paid cost/time estimates.
- `MOSAIC_CLOUD_CONFIG` real mode passes on an RTX 4090: upload, readiness, estimate, start, status, cached runtime reuse, readable MP4 download, and ffprobe validation all succeed.
- A separate real 60-second baseline run was cancelled after remote start; Core returned `Cancelled`, the remote job state became `cancelled`, no local output was created, and no Lada/Jasna process remained.
- P1, P2, P3, and P4 acceptance scripts pass together. P2's local-machine NVIDIA probe remains an expected `SKIP` on Apple Silicon; P4 is the authoritative real cloud NVIDIA acceptance.
- P4 has no remaining implementation or acceptance blocker and may be formally closed.

## Release Candidate Closure
- Release-candidate baseline started from `416a87539a3fb6e90c57c5ffb60c93a909eb286e` with a clean worktree.
- P1 Core, P1 Provider, P1 MVP, P2 Desktop, P3 Long Video, and P4 Cloud Execution local acceptance all pass. P4 real NVIDIA is not rerun because the completed real RTX 4090 acceptance remains authoritative and RunPod is intentionally stopped.
- Rust formatting and Clippy with warnings denied pass; the Swift release build passes.
- Desktop now renders an unavailable cloud price as `Cost unknown` instead of a fake dollar amount, clears stale estimates before a new selection/run, and rejects a whitespace-only cloud configuration before submission.
- `desktop/build/MosaicRestore.app` is an arm64 release app with a valid strict ad-hoc signature. The installed `/Applications/MosaicRestore.app` passes signature verification and launches to its initial usable window.
- Desktop uses one native SwiftUI glass visual system: adaptive Material cards and controls, a single cool accent, consistent rounded geometry, restrained hover/pressed feedback, and solid-surface fallbacks for reduced transparency. The input, Local/Cloud selection, progress, errors, Advanced settings, and actions share these reusable components without changing Core behavior.
- The RC glass baseline uses only public AppKit/SwiftUI APIs: a hidden-titlebar full-size content window, transparent `NSWindow`, and `NSVisualEffectView` with behind-window blending provide real window-level transmission. Reusable glass cards, buttons, and the custom Local/Cloud segmented control add adaptive blur, highlight edges, depth, hover/pressed/disabled/error states, and Reduce Motion/Reduce Transparency fallbacks.
- `verify/verify_glass_ui.sh` performs an actual Release build, validates both bundled executables and the strict app signature, reads bundle metadata, and launches the Desktop process. It passes together with P1–P4 regression, Rust formatting, and Clippy with warnings denied; the installed `/Applications/MosaicRestore.app` was relaunched from a single fresh process and its transparent titlebar, layered cards, and segmented selection states were visually confirmed.
- `desktop/build_app.sh` resolves SwiftPM's active release binary directory instead of copying from the legacy `.build/release` path, preventing a stale Desktop executable from being packaged under newer Xcode output layouts.
- This Mac has no Apple Developer signing identity. Developer ID signing, notarization, and Gatekeeper-ready external distribution remain a release blocker outside the repository; local ad-hoc installation is verified.

## AI-OS Integration Boundary
- AI-OS must call the same Mosaic Core library or CLI contract used by Desktop: `RestoreRequest`, provider-neutral `RestorationProvider`, `ProgressUpdate`, `CancellationToken`, `RestoreErrorKind`, and the P3 production workflow.
- AI-OS must supply external runtime or cloud configuration at the adapter boundary. Vendor credentials, SSH keys, RunPod APIs, Lada source, and Jasna source must not enter Core or AI-OS persistence.
- No AI-OS-specific adapter or vendor branch is added in this closure. Contract and adapter-level fixture coverage are the complete acceptance boundary for this repository; real AI-OS host wiring and its end-to-end acceptance are explicitly deferred to AI-OS v2.0.

## Final Long-Video Cloud Acceptance Checklist
1. Start the retained RunPod only for the acceptance window; confirm the saved SSH profile, `nvidia-smi`, remote runner, pinned Lada commit, weights, and cache without changing Core.
2. Record input path, duration, codec, resolution, size, and SHA-256 for the selected real long video; keep media and credentials outside git.
3. Run the existing production path with the saved cloud configuration. Confirm configuration/readiness, upload, honest time/cost estimate (numeric or `unknown`), chunk progress, cache reuse, download, and terminal success.
4. If the run is interrupted, resume from the durable checkpoint and confirm completed chunks are not repeated. Do not manufacture a retry during the final uninterrupted quality run.
5. Validate the restored output with `ffprobe`; compare duration to input, record codec/resolution/size/SHA-256, and perform the final visual mosaic-restoration review.
6. Confirm successful local workspace cleanup, no remote Lada/Jasna process remains, retain only the intended remote cache, then stop RunPod. Do not terminate it until cache retention is no longer needed.

## Remaining Release Blockers
- Final real long-video cloud quality acceptance has not yet been run; it requires intentionally restarting RunPod.
- External distribution requires a valid Apple Developer signing identity and notarization. The current app is verified only for local ad-hoc installation.
- AI-OS host integration is deferred to AI-OS v2.0 and is not a MosaicRestore release-candidate blocker; it must be accepted in the AI-OS repository against the contract above.
