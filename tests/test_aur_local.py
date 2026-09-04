#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Julien Freyermuth

"""Exercise yaourt's real Babet HTTP/JSON path against a local AUR RPC."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
from threading import Thread
from urllib.parse import parse_qs, urlparse


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("babet", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("--timeout", type=float, default=10.0)
    return parser.parse_args()


class AurHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_chunked_json(self, payload: dict[str, object]) -> None:
        self.send_chunked(
            json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            "application/json",
        )

    def send_chunked(self, body: bytes, content_type: str) -> None:
        midpoint = max(1, len(body) // 2)
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        for chunk in (body[:midpoint], body[midpoint:]):
            if chunk:
                self.wfile.write(f"{len(chunk):X}\r\n".encode("ascii"))
                self.wfile.write(chunk + b"\r\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        request = urlparse(self.path)
        query = parse_qs(request.query)
        entry = {"Name": "yay", "Version": "12.0.0"}

        if (
            request.path == "/cgit/aur.git/plain/.SRCINFO"
            and query == {"h": ["yay-git"]}
        ):
            self.send_chunked(
                b"pkgbase = yay-git\n"
                b"\tsource = yay::git+https://example.test/yay.git\n"
                b"pkgname = yay-git\n",
                "text/plain; charset=utf-8",
            )
            return

        if request.path == "/rpc/v5/info" and query == {"arg[]": ["yay"]}:
            self.send_chunked_json({
                "type": "multiinfo",
                "resultcount": 1,
                "results": [entry],
            })
            return

        if request.path == "/rpc/v5/search/yay" and query == {"by": ["name"]}:
            self.send_chunked_json({
                "type": "search",
                "resultcount": 1,
                "results": [entry],
            })
            return

        if (
            request.path == "/rpc/v5/search/virtual-tool"
            and query == {"by": ["provides"]}
        ):
            self.send_chunked_json({
                "type": "search",
                "resultcount": 1,
                "results": [{"Name": "tool-provider", "Version": "2.0.0"}],
            })
            return

        if (
            request.path == "/rpc/v5/info"
            and query == {"arg[]": ["tool-provider"]}
        ):
            self.send_chunked_json({
                "type": "multiinfo",
                "resultcount": 1,
                "results": [{
                    "Name": "tool-provider",
                    "Version": "2.0.0",
                    "Provides": ["virtual-tool=2"],
                }],
            })
            return

        self.send_error(404)


def main() -> int:
    args = parse_args()
    babet = args.babet.resolve()
    project = args.project.resolve()
    test_project = project / "tests" / "local_network"
    server = ThreadingHTTPServer(("127.0.0.1", 0), AurHandler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()

    env = os.environ.copy()
    env["YAOURT_TEST_AUR_URL"] = (
        f"http://127.0.0.1:{server.server_address[1]}"
    )
    try:
        result = subprocess.run(
            [str(babet), str(test_project)],
            cwd=project,
            env=env,
            capture_output=True,
            text=True,
            timeout=args.timeout,
            check=False,
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    if result.returncode != 0 or "YAOURT_LOCAL_AUR_OK" not in result.stdout:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError(
            f"intégration AUR locale terminée avec le code {result.returncode}"
        )

    print("[PASS] client AUR réel : HTTP chunked local et JSON")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"[FAIL] intégration AUR locale : {exc}", file=sys.stderr)
        raise SystemExit(1)
