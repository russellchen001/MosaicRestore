# MosaicRestore

MosaicRestore is a local-first AI video mosaic-restoration application for macOS, with an optional provider-neutral cloud execution path for NVIDIA GPUs. It combines a Rust core workflow with a native SwiftUI desktop app while keeping model runtimes replaceable and outside the proprietary core.

> [!IMPORTANT]
> AI restoration produces a plausible reconstruction. It cannot recover the original, factual pixels hidden by a mosaic or other censorship.

## Core capabilities

- Restore a single video through the native macOS desktop app.
- Process long videos with deterministic chunking, durable checkpoints, resume, bounded retry, validated assembly, and cancellation.
- Run locally on Apple Silicon with an external Lada/MPS runtime.
- Run on a user-funded NVIDIA host through a provider-neutral SSH adapter and an external Lada/CUDA runner.
- Run through an authenticated Agent Cloud Computer that controls an external GPU desktop without adding an AI-OS-specific provider branch.
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

### Agent Cloud Computer

Advanced users can supply an authenticated external agent configuration for a rented GPU desktop. Mosaic Core owns the provider lifecycle while the external agent performs visible GUI actions, preserves a reconnectable session, reports progress, supports cancellation, and returns a validated result. Provider credentials and rented-machine details remain outside the repository.

## Project status

MosaicRestore **v1.0.0** is complete as a source release. P1–P5 and all three execution chains are genuinely accepted: Local Computer, Cloud Compute, and Agent Cloud Computer. The final quality gate used a real 70-minute video through the existing 15-chunk production path; the output passed full decode, duration, frame-count, timestamp, boundary, and sampled visual-quality checks.

This Mac has no Apple Developer ID identity. The repository therefore does not publish an unsigned app as a formal macOS distribution artifact: local ad-hoc installation is verified, while Developer ID signing, notarization, stapling, and Gatekeeper-ready external app distribution remain an external release blocker.

The AI-OS integration contract is defined, but real AI-OS host wiring and end-to-end acceptance are intentionally deferred to AI-OS v2.0. MosaicRestore remains an independent repository and product boundary.

## Build and verification

Requirements include macOS, Xcode/Swift, Rust, `ffmpeg`, and `ffprobe`. Model runtimes and weights are external dependencies and are not bundled in this repository.

```bash
desktop/build_app.sh
verify/verify_p1_mvp.sh
verify/verify_p2_desktop.sh
verify/verify_p3_long_video.sh
verify/verify_p4_cloud_execution.sh
verify/verify_p5_agent_cloud_computer.sh
verify/verify_glass_ui.sh
```

The P4 script always exercises the provider contract locally. A real NVIDIA run additionally requires a valid `MOSAIC_CLOUD_CONFIG` and a prepared external host; otherwise that external portion reports `SKIP` rather than a false pass.

## Privacy and cost model

Local execution keeps media on the user's Mac. Cloud execution transfers media only to the host selected and configured by the user. MosaicRestore does not provision vendor accounts, store provider credentials in Core, or absorb GPU charges. Review the privacy, retention, and pricing terms of any external runtime or cloud provider before use.

## License

No license is currently provided for this repository. All rights are reserved until a separate `LICENSE` file is added. Third-party runtimes, models, and tools remain subject to their own licenses.
