#!/usr/bin/env python3
"""One paid-window gate for Jasna Cloud Compute and Agent Cloud Computer."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def run(command, *, env=None, timeout=300, log=None):
    with (log.open("w") if log else open(os.devnull, "w")) as output:
        return subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT,
                              timeout=timeout, check=True)


def probe(path: Path, destination: Path) -> dict:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        capture_output=True, check=True, timeout=20,
    )
    destination.write_bytes(result.stdout)
    payload = json.loads(result.stdout)
    if not any(stream.get("codec_type") == "video" for stream in payload.get("streams", [])):
        raise RuntimeError(f"no readable video stream in {path}")
    return payload


def main(args):
    started = time.monotonic()
    connection = json.loads(args.connection.read_text(encoding="utf-8"))
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    profile = args.output / "http-profiles"
    profile.mkdir()
    token_name = "MOSAIC_JASNA_WINDOW_TOKEN"
    (profile / "jasna.conf").write_text(
        f"endpoint={connection['endpoint']}\ntoken_env={token_name}\ntimeout_seconds=15\n",
        encoding="utf-8",
    )
    cloud = args.output / "jasna-cloud.conf"
    cloud.write_text(
        f"version=1\nadapter={ROOT / 'adapters/http_jasna_cloud_adapter.py'}\n"
        "profile=jasna\nstatus_retries=2\npoll_millis=500\n",
        encoding="utf-8",
    )
    sessions = args.output / "cloud-sessions"
    env = dict(os.environ, **{token_name: connection["token"]},
               MOSAIC_AGENT_CLOUD_HTTP_PROFILE_DIR=str(profile),
               MOSAIC_JASNA_SESSION_DIR=str(sessions))
    cloud_output = args.output / "cloud-compute.mp4"
    run([str(args.core), "--provider", "cloud-nvidia", "--cloud-config", str(cloud),
         "--input", str(args.input), "--output", str(cloud_output)],
        env=env, timeout=300, log=args.output / "cloud-compute.log")
    probe(cloud_output, args.output / "cloud-compute-ffprobe.json")
    session_files = list(sessions.glob("*.session"))
    if len(session_files) != 1:
        raise RuntimeError("Cloud Compute did not preserve exactly one evidence session")
    run([str(ROOT / "adapters/http_jasna_cloud_adapter.py"), "evidence", "--profile", "jasna",
         "--job", session_files[0].stem, "--output", str(args.output / "cloud-compute-evidence.zip")],
        env=env, timeout=30, log=args.output / "cloud-evidence.log")
    run(["python3", str(ROOT / "verify/run_p5_real.py"), "--connection", str(args.connection),
         "--output", str(args.output / "agent-cloud-computer"), "--core", str(args.core),
         "--minutes", "6"], timeout=420, log=args.output / "agent-cloud-computer.log")
    report = {
        "result": "PASS",
        "runtime": "Jasna v0.10.0 Windows NVIDIA TensorRT",
        "cloud_compute_sha256": hashlib.sha256(cloud_output.read_bytes()).hexdigest(),
        "agent_cloud_report": "agent-cloud-computer/report.json",
        "elapsed_seconds": round(time.monotonic() - started, 1),
        "paid_resource_started_by_script": False,
    }
    (args.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("PASS Jasna Cloud Compute + Agent Cloud Computer — stop AirGPU immediately")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--connection", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--input", type=Path, default=ROOT / "benchmark/samples/p1_lada_smoke.mp4")
    parser.add_argument("--core", type=Path, default=ROOT / "core/target/release/mosaic-core")
    try:
        main(parser.parse_args())
    except Exception as error:
        print(f"FAIL Jasna dual-path acceptance: {error}; stop AirGPU immediately")
        raise SystemExit(1)
