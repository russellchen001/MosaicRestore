#!/usr/bin/env python3
"""Provider-neutral controller for a remote Agent Cloud Computer HTTP relay."""

from __future__ import annotations

import http.client
import os
import re
import sys
import urllib.parse
from pathlib import Path


def fail(kind: str, message: str, code: int = 1) -> None:
    print(f"error_kind={kind}", file=sys.stderr)
    print(f"message={message}", file=sys.stderr)
    raise SystemExit(code)


def parse_cli(argv: list[str]) -> tuple[str, dict[str, str]]:
    if not argv:
        fail("invalid-request", "missing action", 2)
    action = argv[0]
    values: dict[str, str] = {}
    index = 1
    while index < len(argv):
        if index + 1 >= len(argv) or not argv[index].startswith("--"):
            fail("invalid-request", f"invalid argument {argv[index]}", 2)
        values[argv[index][2:]] = argv[index + 1]
        index += 2
    return action, values


def read_profile(name: str) -> dict[str, str]:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        fail("invalid-request", "invalid profile", 2)
    root = Path(
        os.environ.get(
            "MOSAIC_AGENT_CLOUD_HTTP_PROFILE_DIR",
            Path.home() / ".config/mosaicrestore/http-agent-profiles",
        )
    )
    path = root / f"{name}.conf"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        fail("invalid-request", f"failed to read controller profile: {error}", 2)
    values: dict[str, str] = {}
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            fail("invalid-request", f"invalid controller profile line {number}", 2)
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    for key in ("endpoint", "token_env"):
        if not values.get(key):
            fail("invalid-request", f"controller profile requires {key}", 2)
    endpoint = urllib.parse.urlsplit(values["endpoint"])
    if endpoint.scheme != "https" or not endpoint.hostname:
        fail("invalid-request", "controller endpoint must be an https URL", 2)
    token = os.environ.get(values["token_env"], "")
    if not token:
        fail("provider-unavailable", "agent relay token environment variable is missing", 3)
    values["token"] = token
    return values


class Relay:
    def __init__(self, profile: dict[str, str]) -> None:
        self.profile = profile
        self.url = urllib.parse.urlsplit(profile["endpoint"])
        self.prefix = self.url.path.rstrip("/")

    def connection(self) -> http.client.HTTPSConnection:
        return http.client.HTTPSConnection(
            self.url.hostname,
            self.url.port or 443,
            timeout=float(self.profile.get("timeout_seconds", "30")),
        )

    def request(
        self,
        method: str,
        path: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> bytes:
        request_headers = {
            "Authorization": f"Bearer {self.profile['token']}",
            "Accept": "text/plain",
            "User-Agent": "MosaicRestore-P5/1.0",
        }
        if headers:
            request_headers.update(headers)
        connection = self.connection()
        try:
            connection.request(method, f"{self.prefix}{path}", body=body, headers=request_headers)
            response = connection.getresponse()
            payload = response.read()
        except (OSError, http.client.HTTPException) as error:
            fail("provider-unavailable", f"agent relay connection failed: {error}", 3)
        finally:
            connection.close()
        if response.status < 200 or response.status >= 300:
            text = payload.decode("utf-8", errors="replace").strip()
            kind = "provider-unavailable" if response.status >= 500 else "execution-failed"
            fail(kind, text or f"agent relay returned HTTP {response.status}", 4)
        return payload

    def upload(self, path: str, source: Path) -> None:
        size = source.stat().st_size
        connection = self.connection()
        try:
            connection.putrequest("PUT", f"{self.prefix}{path}")
            connection.putheader("Authorization", f"Bearer {self.profile['token']}")
            connection.putheader("User-Agent", "MosaicRestore-P5/1.0")
            connection.putheader("Content-Type", "application/octet-stream")
            connection.putheader("Content-Length", str(size))
            connection.endheaders()
            with source.open("rb") as handle:
                while chunk := handle.read(1024 * 1024):
                    connection.send(chunk)
            response = connection.getresponse()
            payload = response.read()
        except (OSError, http.client.HTTPException) as error:
            fail("provider-unavailable", f"agent upload failed: {error}", 3)
        finally:
            connection.close()
        if response.status < 200 or response.status >= 300:
            fail(
                "execution-failed",
                payload.decode("utf-8", errors="replace").strip()
                or f"agent upload returned HTTP {response.status}",
                4,
            )

    def download(self, path: str, destination: Path) -> None:
        connection = self.connection()
        temporary = destination.with_name(f".{destination.name}.agent-download")
        try:
            connection.request(
                "GET",
                f"{self.prefix}{path}",
                headers={"Authorization": f"Bearer {self.profile['token']}"},
            )
            response = connection.getresponse()
            if response.status < 200 or response.status >= 300:
                payload = response.read().decode("utf-8", errors="replace").strip()
                fail("output-missing", payload or "agent result is unavailable", 4)
            with temporary.open("wb") as handle:
                while chunk := response.read(1024 * 1024):
                    handle.write(chunk)
            temporary.replace(destination)
        except (OSError, http.client.HTTPException) as error:
            temporary.unlink(missing_ok=True)
            fail("provider-unavailable", f"agent download failed: {error}", 3)
        finally:
            connection.close()


def require(values: dict[str, str], name: str) -> str:
    value = values.get(name, "")
    if not value:
        fail("invalid-request", f"missing --{name}", 2)
    return value


def print_response(payload: bytes) -> None:
    sys.stdout.write(payload.decode("utf-8", errors="replace"))
    if payload and not payload.endswith(b"\n"):
        sys.stdout.write("\n")


def main() -> None:
    action, args = parse_cli(sys.argv[1:])
    profile_name = require(args, "profile")
    profile = read_profile(profile_name)
    relay = Relay(profile)
    job = args.get("job", "")
    session = args.get("session", "")

    if action == "validate":
        relay.request("GET", "/v1/health")
        print("contract_version=1")
        print("transport=agent-gui")
        print(f"runtime={profile.get('runtime', 'windows-uia')}")
    elif action == "open-session":
        require(args, "job")
        print_response(relay.request("POST", f"/v1/jobs/{job}/session"))
    elif action == "readiness":
        require(args, "job")
        require(args, "session")
        print_response(relay.request("GET", f"/v1/jobs/{job}/readiness?session={session}"))
    elif action == "upload":
        require(args, "job")
        require(args, "session")
        source = Path(require(args, "input"))
        if not source.is_file():
            fail("invalid-request", "upload input is missing", 2)
        relay.upload(f"/v1/jobs/{job}/input?session={session}", source)
    elif action == "estimate":
        require(args, "job")
        require(args, "session")
        print_response(relay.request("GET", f"/v1/jobs/{job}/estimate?session={session}"))
    elif action == "start":
        require(args, "job")
        require(args, "session")
        print_response(relay.request("POST", f"/v1/jobs/{job}/start?session={session}"))
    elif action == "status":
        require(args, "job")
        require(args, "session")
        print_response(relay.request("GET", f"/v1/jobs/{job}/status?session={session}"))
    elif action == "reconnect":
        require(args, "job")
        require(args, "session")
        print_response(relay.request("POST", f"/v1/jobs/{job}/reconnect?session={session}"))
    elif action == "cancel":
        require(args, "job")
        require(args, "session")
        print_response(relay.request("POST", f"/v1/jobs/{job}/cancel?session={session}"))
    elif action == "download":
        require(args, "job")
        require(args, "session")
        relay.download(
            f"/v1/jobs/{job}/output?session={session}",
            Path(require(args, "output")),
        )
    elif action == "metadata":
        require(args, "job")
        require(args, "session")
        print_response(relay.request("GET", f"/v1/jobs/{job}/metadata?session={session}"))
    elif action == "cleanup":
        require(args, "job")
        require(args, "session")
        print_response(relay.request("DELETE", f"/v1/jobs/{job}?session={session}"))
    else:
        fail("invalid-request", f"unknown action: {action}", 2)


if __name__ == "__main__":
    main()
