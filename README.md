# MosaicRestore

**MosaicRestore — AI Video Mosaic Removal and Restoration for macOS**

MosaicRestore is a local-first AI video mosaic removal and restoration application for macOS.

It is designed for long-form video restoration with Apple Silicon local processing and an optional provider-neutral NVIDIA cloud execution path.

MosaicRestore combines:

- AI video mosaic detection
- AI video restoration
- long-video chunk processing
- checkpoint and resume
- native macOS SwiftUI desktop UI
- Apple Silicon / MPS local execution
- optional NVIDIA / TensorRT cloud execution
- privacy-first local processing

> [!IMPORTANT]
> AI restoration generates a plausible reconstruction. It cannot recover the original factual pixels that were permanently hidden by a mosaic or censorship.

## Latest release

**Latest prerelease: MosaicRestore v1.0.1 Beta 3**

- macOS
- Apple Silicon
- App version: `1.0.1 (105)`
- DMG available from GitHub Releases

Download:

https://github.com/russellchen001/MosaicRestore/releases/tag/v1.0.1-beta.3

DMG:

`MosaicRestore-1.0.1-beta.3-arm64.dmg`

SHA-256:

`8b87eb48ad2002cb16904409badec0ea5f396b853b4a952b9e6ea5326a451cb1`

## What MosaicRestore does

MosaicRestore is built for AI-assisted restoration of videos containing mosaic censorship or similar obscured regions.

The application supports:

- video mosaic removal workflows
- mosaic detection and restoration
- AI video restoration
- long-form video processing
- automatic chunking
- checkpoint recovery
- cancellation and resume
- local Apple Silicon processing
- NVIDIA cloud processing
- validated final video assembly

## Core capabilities

- Restore a single video through the native macOS desktop app.
- Process long videos with deterministic chunking.
- Resume interrupted jobs using durable checkpoints.
- Show long-video segment progress, processing speed and remaining time when available.
- Validate final outputs before completion.
- Run locally on Apple Silicon using Lada and Apple MPS.
- Run through a provider-neutral NVIDIA cloud execution path.
- Keep local video data on the Mac when Local mode is selected.

## Local processing

Local mode runs on Apple Silicon using the bundled Lada runtime.

Current Beta 3 local restoration stack:

- Lada
- Apple MPS
- Lada YOLO `v4-accurate` detector by default
- Lada YOLO `v4-fast` retained as an alternate bundled detector
- BasicVSR++ v1.2 restoration
- bundled FFmpeg / ffprobe

The default detector was changed to `v4-accurate` in v1.0.1 Beta 3 after real-world Beta testing found residual mosaic regions with the faster detector.

## Cloud processing

MosaicRestore also supports an optional provider-neutral Cloud mode for NVIDIA GPU hosts.

The formal Cloud Compute path uses:

- Windows
- NVIDIA GPU
- Jasna v0.10.0
- Lada YOLO v4 detection
- BasicVSR++
- TensorRT FP16

The native Cloud adapter handles:

- authenticated connection
- upload
- readiness checks
- remote execution
- progress monitoring
- reconnect
- cancellation
- download
- output validation

Large-file transfers use file-backed streaming upload/download rather than buffering entire videos in application memory.

## Long-video support

MosaicRestore is designed around long-form video processing rather than only short clips.

The production workflow includes:

- deterministic video chunking
- checkpoint persistence
- resume after interruption
- bounded retry
- validated chunk assembly
- cancellation
- disk-space preflight
- progress aggregation
- segment-level status

Example long-video UI state:

```text
Processing segment 21 of 26…
Segment progress: 43% · 2.4fps · ~36:08 remaining
```

Checkpoint resume example:

```text
Resuming previous restore — 20 of 26 segments already complete
```

## Architecture

### Mosaic Core

Rust-based execution core responsible for:

- request validation
- task lifecycle
- chunk planning
- checkpoint and resume
- cancellation
- progress reporting
- provider abstraction
- output validation
- error mapping

### macOS Desktop

Native SwiftUI application providing:

- Local / Cloud processing modes
- file selection
- output folder management
- progress display
- checkpoint resume visibility
- Cloud setup
- diagnostics
- result navigation

### Provider adapters

Provider-specific implementation details remain outside Mosaic Core.

Supported architecture includes:

- Apple Silicon / MPS
- NVIDIA CUDA
- TensorRT
- Lada
- Jasna
- provider-neutral Cloud relay
- Agent Cloud Computer execution

## Privacy

Local mode keeps video processing on the user's Mac.

Cloud mode sends video only to the cloud host explicitly configured by the user.

MosaicRestore does not require the developer to operate a central GPU service.

Cloud costs are paid directly by the user to their selected provider.

## Beta 3 validation

MosaicRestore v1.0.1 Beta 3 passed:

- 19 Core tests
- Swift Release build
- Desktop contract validation
- bundled runtime validation
- real Local smoke restoration
- checkpoint cancellation/resume behavior
- segment progress behavior
- v4-accurate model verification
- DMG mount/install verification
- installed application signature verification
- native Cloud adapter verification
- 256 MiB streaming upload/download behavior validation

Cloud streaming validation:

- Upload peak RSS: 24,144 KiB
- Upload peak/file ratio: 9.2%
- Download peak RSS: 20,800 KiB
- Download peak/file ratio: 7.9%
- Upload/download SHA preserved exactly

## Build

Requirements for development include:

- macOS
- Apple Silicon recommended for Local mode
- Swift / Xcode toolchain
- Rust
- FFmpeg / ffprobe for development tooling

Build the macOS application:

```bash
bash desktop/build_app.sh
```

Core tests:

```bash
cargo test --manifest-path core/Cargo.toml
```

Desktop contract:

```bash
swift run \
  --package-path desktop \
  -c release \
  MosaicRestoreContractCheck
```

## Project status

Current public Beta:

**MosaicRestore v1.0.1 Beta 3 — build 105**

The independent macOS desktop application is in Beta testing.

Formal Local, Cloud Compute and Agent Cloud Computer execution paths have completed their current acceptance gates.

AI-OS integration is intentionally deferred to AI-OS v2.0 and remains outside the current MosaicRestore desktop release.

## Installation

The current Beta is ad-hoc signed.

It is not Developer ID signed or notarized.

macOS may require:

**System Settings → Privacy & Security → Open Anyway**

## Keywords

MosaicRestore relates to:

- AI video restoration
- video mosaic removal
- mosaic restoration
- video restoration
- mosaic detection
- Apple Silicon AI
- macOS AI video processing
- computer vision
- BasicVSR++
- Lada
- NVIDIA TensorRT
- long video restoration

## License

No repository-level open-source license is currently provided.

All rights are reserved.

Third-party runtimes, models and tools retain their respective licenses.
