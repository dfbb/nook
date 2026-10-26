#!/usr/bin/env python3
"""Serve deterministic RSS fixtures with deterministic per-path latency."""

import argparse
import hashlib
import http.server
import mimetypes
import pathlib
import time


class FeedHandler(http.server.SimpleHTTPRequestHandler):
    root: pathlib.Path
    latency_seed: int

    def translate_path(self, path: str) -> str:
        relative = self.path.split("?", 1)[0].split("#", 1)[0].lstrip("/")
        candidate = (self.root / relative).resolve()
        try:
            candidate.relative_to(self.root)
        except ValueError:
            return str(self.root / "__not_found__")
        return str(candidate)

    def do_GET(self) -> None:
        digest = hashlib.sha256(f"{self.latency_seed}:{self.path}".encode()).digest()
        latency_ms = 50 + int.from_bytes(digest[:4], "big") % 751
        time.sleep(latency_ms / 1000)
        super().do_GET()

    def guess_type(self, path: str) -> str:
        if path.endswith(".xml"):
            return "application/rss+xml"
        return mimetypes.guess_type(path)[0] or "application/octet-stream"

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.address_string()} [{self.log_date_time_string()}] {fmt % args}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=pathlib.Path)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--latency-seed", type=int, default=7)
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir():
        parser.error(f"root is not a directory: {root}")
    FeedHandler.root = root
    FeedHandler.latency_seed = args.latency_seed
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), FeedHandler)
    print(f"serving {root} on http://127.0.0.1:{args.port} seed={args.latency_seed}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
