# MosaicRestore v1.0.0

MosaicRestore v1.0.0 completes the independent source release for all three accepted execution chains:

- Local Computer — Apple Silicon/MPS with an external Lada runtime.
- Cloud Compute — provider-neutral NVIDIA execution, accepted on RunPod RTX 4090.
- Agent Cloud Computer — authenticated GPU desktop control with real GUI launch, reconnect, download, cancellation, and process-exit evidence.

## Release validation

- P1–P5 serial acceptance passes.
- Rust formatting and Clippy with warnings denied pass.
- Swift Release, Desktop contract/launch, and glass UI acceptance pass.
- The final real-video quality gate processed a 4,224.253-second H.264/AAC 1280×720 sample through 15 production chunks with checkpointing, zero retries, validated assembly, and cleanup.
- The 4,224.736-second output retained all 126,600 video frames, decoded completely, used monotonic audio/video DTS, and introduced no new freeze event. Sampled full-duration and consecutive-sequence review found consistent mosaic replacement with no obvious missed target, timing jump, flicker, or severe artifact.

## Published runtime evidence

P5 used the public image `ghcr.io/russellchen001/mosaicrestore-p5-linux-desktop:20261004-rfb1`.

- OCI index: `sha256:efc10d5eea8599e5297a06aebf9b6f36e899db7fa285e5056b93a8e2c088ced6`
- amd64 manifest: `sha256:a0635dce42adeca070e0082999635898a40ecf6acd270910f45ec2b63320dc93`

The image keeps Lada and its third-party dependencies outside the proprietary Core/Desktop boundary. Their own licenses continue to apply.

## Distribution and known limits

- This release is source-only. No unsigned or ad-hoc-signed app is attached as a formal public macOS distribution artifact.
- Developer ID signing, notarization, stapling, and Gatekeeper-ready external app distribution remain blocked by the absence of a local Apple Developer ID identity.
- AI restoration generates a plausible reconstruction; it cannot recover factual pixels hidden by censorship.
- AI-OS v2.0 only needs host wiring to the accepted Mosaic Core/CLI contract. AI-OS was not modified for this release.
- The repository does not currently include a `LICENSE` file. All rights are reserved; third-party runtimes, models, and tools remain governed by their own licenses.
