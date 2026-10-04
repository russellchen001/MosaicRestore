# MosaicRestore

MosaicRestore is a local-first AI video mosaic-restoration application for macOS, with an optional provider-neutral cloud execution path for NVIDIA GPUs. It combines a Rust core workflow with a native SwiftUI desktop app while keeping model runtimes replaceable and outside the proprietary core.

> [!IMPORTANT]
> AI restoration produces a plausible reconstruction. It cannot recover the original, factual pixels hidden by a mosaic or other censorship.

## Core capabilities

- Restore a single video through the native macOS desktop app.
- Process long videos with deterministic chunking, durable checkpoints, resume, bounded retry, validated assembly, and cancellation.
- Run locally on Apple Silicon with an external Lada/MPS runtime.
- Run headless Jasna/NVIDIA/TensorRT on a user-funded cloud host.
- Run Jasna through an authenticated Agent Cloud Computer that performs visible actions on an external GPU desktop.
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

Advanced users can supply a `MOSAIC_CLOUD_CONFIG` profile for a user-controlled NVIDIA host. The formal runtime is pinned Jasna v0.10.0 with Lada YOLO v4 detection, BasicVSR++ restoration and a prebuilt TensorRT cache. MosaicRestore uploads the input, checks readiness, runs Jasna headlessly, monitors it, downloads the result and validates the output. Provider credentials remain outside the repository, and GPU charges are paid directly by the user.

### Agent Cloud Computer

Advanced users can supply an authenticated external agent configuration for a rented Windows GPU desktop. Mosaic Core owns the provider lifecycle while the external agent performs visible GUI actions that launch the same pinned Jasna runtime, preserves a reconnectable session, reports progress, supports cancellation, and returns a validated result.

## Project status

MosaicRestore **v1.0.0** is published as a source release. Local Computer (Lada/MPS) and its real 70-minute, 15-chunk quality gate are accepted. Earlier RunPod Lada/CUDA P4/P5 runs validate upload, download, relay, session, cancellation and GUI-agent infrastructure only; they do not complete the formal Jasna Cloud Compute or Agent Cloud Computer product gates. Both Jasna paths are offline-ready and await one bounded Windows/T4 E2E window.

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
verify/verify_jasna_airgpu.sh --offline
verify/verify_glass_ui.sh
```

The P4/P5 scripts preserve Lada/CUDA infrastructure coverage. They are not formal Jasna cloud product acceptance. The dual-path Jasna gate uses `verify/verify_jasna_airgpu.sh --real --connection <secret.json> --output <new-evidence-directory>` after a separately approved AirGPU start; it never starts or purchases the machine itself.

## Privacy and cost model

Local execution keeps media on the user's Mac. Cloud execution transfers media only to the host selected and configured by the user. MosaicRestore does not provision vendor accounts, store provider credentials in Core, or absorb GPU charges. Review the privacy, retention, and pricing terms of any external runtime or cloud provider before use.

## License

No license is currently provided for this repository. All rights are reserved until a separate `LICENSE` file is added. Third-party runtimes, models, and tools remain subject to their own licenses.
