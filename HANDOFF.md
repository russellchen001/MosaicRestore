# MosaicRestore — HANDOFF

## Current Phase
P1 — Mosaic Core MVP.

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

## P1 Provider Decision
Mosaic Core exposes a provider-neutral RestorationProvider contract.
Execution providers declare supported compute backends before execution.
Lada, Jasna, MPS, CUDA and TensorRT implementation details remain outside the Core contract.
