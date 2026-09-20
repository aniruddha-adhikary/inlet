from __future__ import annotations

import argparse
import json
import sys

from .profiles import REPO_ROOT, ProfileError, load_profiles, load_schemas
from .server import serve
from .store import Store

DEFAULT_DB = REPO_ROOT / ".bridge" / "bridge.db"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="bridge")
    parser.add_argument("--db", default=str(DEFAULT_DB))
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve", help="run the local ingest host").add_argument("--port", type=int, default=8787)
    sub.add_parser("profiles", help="validate and list profiles")
    sub.add_parser("status", help="entity counts, profile health, recent batches")
    sub.add_parser("verify", help="re-hash stored payloads and report tampering")
    sub.add_parser("release", help="lift a profile out of quarantine").add_argument("profile_key")
    args = parser.parse_args(argv)

    try:
        schemas = load_schemas()
        profiles = load_profiles(schemas=schemas)
    except ProfileError as e:
        print(f"profile error: {e}", file=sys.stderr)
        return 2

    if args.cmd == "profiles":
        for p in profiles.values():
            print(f"{p.key:24} {p.data.get('status', '?'):11} {p.schema:18} {','.join(p.hosts)}  sha={p.checksum[:12]}")
        return 0

    store = Store(args.db)
    if args.cmd == "serve":
        serve(store, profiles, schemas, args.port)
    elif args.cmd == "status":
        print(json.dumps(store.summary(), indent=2))
    elif args.cmd == "verify":
        bad = store.verify()
        print("ok: all payload hashes match" if not bad else f"MISMATCH in {len(bad)} rows: {bad[:10]}")
        return 1 if bad else 0
    elif args.cmd == "release":
        print("released" if store.release(args.profile_key) else "no such profile state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
