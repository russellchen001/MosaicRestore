# MosaicRestore

MosaicRestore is a local-first AI video mosaic-restoration application for macOS, with an optional provider-neutral cloud execution path for NVIDIA GPUs. It combines a Rust core workflow with a native SwiftUI desktop app while keeping model runtimes replaceable and outside the proprietary core.

> [!IMPORTANT]
> AI restoration produces a plausible reconstruction. It cannot recover the original, factual pixels hidden by a mosaic or other censorship.

## Core capabilities

- Restore a single video through the native macOS desktop app.
- Process long videos with deterministic chunking, durable checkpoints, resume, bounded retry, validated assembly, and cancellation.
- Run locally on Apple Silicon with an external Lada/MPS runtime.
- Run on a user-funded NVIDIA host through a provider-neutral SSH adapter and an external Lada/CUDA runner.
- Track progress, validate outputs with `ffprobe`, and preserve resumable state after interruption.
- Use a native SwiftUI glass interface with accessibility fallbacks for reduced transparency and motion.

## Architecture

- **Mosaic Core (Rust):** owns validation, task state, chunk planning, checkpoint/resume, progress, cancellation, output validation, and provider-neutral error mapping.
- **Desktop (SwiftUI):** provides the native macOS workflow and invokes the same Core executable used by other hosts.
- **Provider adapters:** keep Apple MPS, CUDA, TensorRT, Lada, Jasna, SSH, and cloud-vendor details outside the Core contract.
- **External runtimes:** Lada and Jasna are installed and executed separately. Their AGPL source code is not copied into the proprietary Core or Desktop source tree.

## Execution modes

### Local Apple Silicon

The default desktop path uses an external Lada runtime with Apple MPS, the Lada YOLO v4-fast detector, and BasicVSR++ restoration. Video data remains on the local Mac.

### Cloud NVIDIA

Advanced users can supply a `MOSAIC_CLOUD_CONFIG` profile for a user-controlled NVIDIA host. MosaicRestore uploads the input, checks GPU/runtime readiness, starts and monitors the external runner, supports cancellation and recovery, downloads the result, and validates the output. The bundled adapter is provider-neutral: credentials and SSH keys stay outside the repository, and GPU charges are paid directly by the user to their chosen provider.

## Project status

MosaicRestore is a **Release Candidate**. P1–P4 are complete: Core MVP, native Desktop, long-video production workflow, and real provider-neutral cloud/NVIDIA execution. The remaining release blockers are the final real long-video cloud quality run and Apple Developer ID signing/notarization for external distribution. Local ad-hoc installation has been verified.

The AI-OS integration contract is defined, but real AI-OS host wiring and end-to-end acceptance are intentionally deferred to AI-OS v2.0. MosaicRestore remains an independent repository and product boundary.

## Build and verification

Requirements include macOS, Xcode/Swift, Rust, `ffmpeg`, and `ffprobe`. Model runtimes and weights are external dependencies and are not bundled in this repository.

```bash
desktop/build_app.sh
verify/verify_p1_mvp.sh
verify/verify_p2_desktop.sh
verify/verify_p3_long_video.sh
verify/verify_p4_cloud_execution.sh
verify/verify_glass_ui.sh
```

The P4 script always exercises the provider contract locally. A real NVIDIA run additionally requires a valid `MOSAIC_CLOUD_CONFIG` and a prepared external host; otherwise that external portion reports `SKIP` rather than a false pass.

## Privacy and cost model

Local execution keeps media on the user's Mac. Cloud execution transfers media only to the host selected and configured by the user. MosaicRestore does not provision vendor accounts, store provider credentials in Core, or absorb GPU charges. Review the privacy, retention, and pricing terms of any external runtime or cloud provider before use.

## License

No license is currently provided for this repository. All rights are reserved until a separate `LICENSE` file is added. Third-party runtimes, models, and tools remain subject to their own licenses.
