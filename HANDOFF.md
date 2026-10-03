# MosaicRestore — HANDOFF

## Current Phase
P4 — Cloud Execution implementation and local automated acceptance complete on 2026-10-03.
Final P4 completion is blocked only by one real NVIDIA/Jasna end-to-end run: this Mac currently has no `MOSAIC_CLOUD_CONFIG`, cloud host profile, or available NVIDIA machine connection.

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
- NVIDIA/cloud baseline: Jasna pipeline + Lada YOLO v4 detector + BasicVSR++ + TensorRT.
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
Local Lada on Apple MPS is the default. Cloud/NVIDIA remains an Advanced provider entry that accepts an external Jasna runner and does not block local Desktop use.
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
configuration validation → upload → GPU/driver/CUDA/TensorRT/Jasna/Lada-detector readiness → estimate → remote start/progress → cancellation/recovery → download → existing P3 output validation.
Desktop keeps Local Lada/MPS as the simple default and exposes the real Cloud/NVIDIA path only under Advanced.

## P4 Technical Decision
Cloud execution uses a versioned external adapter command contract owned by Mosaic Core; Core does not contain AirGPU, RunPod, or another vendor API.
The bundled generic SSH adapter can target AirGPU, RunPod, or a user-owned NVIDIA host through a named profile. Provider credentials and SSH keys remain outside the app and repository, and GPU charges are paid directly by the user.
The remote runner remains external and must provide Jasna pipeline execution with Lada YOLO v4 detection, BasicVSR++ restoration, TensorRT backend, persistent engine-cache reuse, job status, and cancellation. No Jasna or Lada AGPL upstream source is copied into Core or Desktop.
P3 chunking/checkpoint behavior remains above the provider boundary, so cloud jobs inherit bounded retry, crash resume, batch ordering, final ffprobe validation, and cleanup semantics.

## P4 Verification
- `verify/verify_p4_cloud_execution.sh` is the P4 acceptance entry point.
- Executable fixture coverage passes for cloud configuration validation, upload/download, complete NVIDIA runtime readiness, exact Jasna/Lada/TensorRT runner arguments, progress, remote cancellation, transient connection recovery, TensorRT cache hit, cost/time estimate, and output integrity.
- Rust Core has 14 passing behavior tests, including cloud success, readiness rejection, cancellation, and transient status recovery.
- Desktop contract compiles and passes with the Xcode beta toolchain; the Advanced Cloud/NVIDIA path submits `cloud-nvidia` configuration and displays progress plus user-paid cost/time estimates.
- Real NVIDIA/Jasna/Lada detector end-to-end is `SKIP` until the user supplies one available machine through `MOSAIC_CLOUD_CONFIG`. This is the only remaining P4 completion blocker.
