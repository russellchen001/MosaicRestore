#!/usr/bin/env python3
"""Build an offline Windows deployment bundle; never starts cloud resources."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "2026.9.3"
SHA256 = "f096265ec2fcbe9bb6e2d64268db167ced3fcbb83d894bdb9e2fcdb26f2ea7e2"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise RuntimeError("output already exists; choose a new path")
    with tempfile.TemporaryDirectory(prefix="mosaic-p5-bundle-") as scratch:
        bundle = Path(scratch)
        for name in ("windows_gui_agent.py", "deploy_windows_agent.ps1", "deploy_windows_agent.cmd",
                     "deploy_windows_jasna.cmd", "jasna-airgpu-v0.10.0.json"):
            shutil.copy2(ROOT / "adapters" / name, bundle / name)
        binary = bundle / "cloudflared.exe"
        url = f"https://github.com/cloudflare/cloudflared/releases/download/{VERSION}/cloudflared-windows-amd64.exe"
        with urllib.request.urlopen(url, timeout=60) as response, binary.open("wb") as handle:
            shutil.copyfileobj(response, handle)
        if hashlib.sha256(binary.read_bytes()).hexdigest() != SHA256:
            raise RuntimeError("official cloudflared release checksum mismatch")
        for abi in ("311", "312"):
            subprocess.run([
                "python3", "-m", "pip", "download", "--disable-pip-version-check",
                "--only-binary=:all:", "--platform", "win_amd64", "--implementation", "cp",
                "--python-version", abi, "--abi", "cp" + abi,
                "--dest", str(bundle / "wheels" / abi),
                "pywinauto==0.6.9", "Pillow==11.3.0", "pywin32==311", "comtypes==1.4.11",
            ], check=True, timeout=180)
        # Include upstream license text beside the downloaded binary.
        with urllib.request.urlopen(f"https://raw.githubusercontent.com/cloudflare/cloudflared/{VERSION}/LICENSE", timeout=30) as response:
            (bundle / "CLOUDFLARED-LICENSE.txt").write_bytes(response.read())
        manifest = {str(path.relative_to(bundle)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in bundle.rglob("*") if path.is_file()}
        (bundle / "SHA256.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(bundle.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(bundle))
    print(f"PASS P5 offline deployment bundle: {args.output}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL P5 offline deployment bundle: {error}")
        raise SystemExit(1)
