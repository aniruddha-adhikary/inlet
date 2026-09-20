"""Local HTTP endpoint the browser extension talks to. Binds to loopback only."""

from __future__ import annotations

import json
import mimetypes
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import integrity
from .profiles import REPO_ROOT, Profile
from .store import Store

MAX_BODY = 5 * 1024 * 1024
STATIC = {
    "/fixture/": REPO_ROOT / "dev" / "harness" / "fixtures",
    "/ext/": REPO_ROOT / "readers",
}
ORIGIN_OK = re.compile(r"^(chrome-extension://[a-p]{32}|http://(127\.0\.0\.1|localhost):\d+)$")


def ingest(store: Store, profiles: dict[str, Profile], schemas: dict, batch: dict) -> tuple[int, dict]:
    """Returns (http_status, response_body)."""
    key = f"{batch.get('profile')}@{batch.get('profileVersion')}"
    profile = profiles.get(key)
    if profile is None:
        return 404, {"error": f"unknown profile {key}"}
    if store.profile_status(key) == "quarantined":
        return 423, {"error": f"profile {key} is quarantined", "status": "quarantined"}
    items = batch.get("items")
    if not isinstance(items, list):
        return 400, {"error": "items must be a list"}

    view_stats = batch.get("viewStats") or {"total": 0, "filled": {}}
    ok, failures = integrity.canary(profile.data["canary"], view_stats)
    health = store.record_canary(key, ok, batch.get("fingerprint"))
    counts = {"seen": len(items), "inserted": 0, "updated": 0, "unchanged": 0, "rejected": 0}

    # A failed canary means we no longer trust this profile's reading of the
    # page, so nothing from the batch is stored.
    if ok:
        schema = schemas[profile.schema]
        for raw in items:
            record, _problems = integrity.normalize(raw, schema)
            if record is None:
                counts["rejected"] += 1
                continue
            eid = integrity.entity_id(profile.app_id, profile.schema, record["sourceId"])
            counts[
                store.upsert(eid, profile.app_id, profile.schema, record, integrity.content_hash(record), profile)
            ] += 1

    detail = failures + (["fingerprint drift"] if health["drift"] else [])
    store.log_batch(profile, batch, counts, ok, detail)
    body = {"canary": "ok" if ok else "failed", "detail": detail, "status": health["status"], **counts}
    return (200 if ok else 422), body


def make_handler(store: Store, profiles: dict[str, Profile], schemas: dict, port: int):
    lock = threading.Lock()
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}

    class Handler(BaseHTTPRequestHandler):
        server_version = "InletHarness/0.1"

        def log_message(self, fmt, *args):  # quieter than the default
            print(f"  {self.command} {self.path} -> {args[1] if len(args) > 1 else ''}")

        def _json(self, status: int, body: dict):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _guard(self) -> bool:
            # Host check defeats DNS rebinding; Origin check keeps arbitrary
            # web pages from writing into the store.
            if self.headers.get("Host") not in allowed_hosts:
                self._json(403, {"error": "bad host"})
                return False
            origin = self.headers.get("Origin")
            if self.command == "POST" and not (origin and ORIGIN_OK.match(origin)):
                self._json(403, {"error": "bad origin"})
                return False
            return True

        def do_GET(self):
            if not self._guard():
                return
            url = urlparse(self.path)
            if url.path == "/profiles":
                host = parse_qs(url.query).get("host", [""])[0]
                with lock:
                    live = [
                        p.data
                        for p in profiles.values()
                        if host in p.hosts and store.profile_status(p.key) != "quarantined"
                    ]
                return self._json(200, {"profiles": live})
            if url.path == "/status":
                with lock:
                    return self._json(200, store.summary())
            for prefix, root in STATIC.items():
                if url.path.startswith(prefix):
                    return self._static(root, url.path[len(prefix) :])
            self._json(404, {"error": "not found"})

        def do_POST(self):
            if not self._guard():
                return
            if urlparse(self.path).path != "/ingest":
                return self._json(404, {"error": "not found"})
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_BODY:
                return self._json(413, {"error": "body too large or empty"})
            try:
                batch = json.loads(self.rfile.read(length))
            except json.JSONDecodeError:
                return self._json(400, {"error": "invalid json"})
            if not isinstance(batch, dict):
                return self._json(400, {"error": "batch must be an object"})
            with lock:
                status, body = ingest(store, profiles, schemas, batch)
            self._json(status, body)

        def _static(self, root, rel: str):
            rel = rel or "index.html"
            if rel.endswith("/"):
                rel += "index.html"
            path = (root / rel).resolve()
            if not path.is_relative_to(root.resolve()) or not path.is_file():
                return self._json(404, {"error": "not found"})
            data = path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

    return Handler


def serve(store: Store, profiles: dict[str, Profile], schemas: dict, port: int = 8787) -> None:
    httpd = ThreadingHTTPServer(("127.0.0.1", port), make_handler(store, profiles, schemas, port))
    print(f"bridge host on http://127.0.0.1:{port}  ({len(profiles)} profiles)")
    print(f"fixture:  http://127.0.0.1:{port}/fixture/demo-chat/")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
