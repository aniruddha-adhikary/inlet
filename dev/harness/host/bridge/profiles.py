"""Load and validate app profiles and the normalized schemas they target."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
PROFILES_DIR = REPO_ROOT / "profiles"
SCHEMAS_DIR = REPO_ROOT / "schemas"

REQUIRED_KEYS = ("profile", "profileVersion", "app", "match", "schema", "canary")
METHODS = ("dom", "page-store")


class ProfileError(ValueError):
    pass


@dataclass(frozen=True)
class Profile:
    name: str
    version: int
    data: dict
    checksum: str  # sha256 of the file bytes: pins stored data to an exact profile revision

    @property
    def key(self) -> str:
        # Several versions of one profile can coexist, each matching a
        # different range of upstream app versions.
        return f"{self.name}@{self.version}"

    @property
    def app_id(self) -> str:
        return self.data["app"]["id"]

    @property
    def schema(self) -> str:
        return self.data["schema"]

    @property
    def hosts(self) -> list[str]:
        return self.data["match"].get("hosts", [])


def load_schemas(directory: Path = SCHEMAS_DIR) -> dict[str, dict]:
    schemas = {}
    for path in sorted(directory.glob("*.json")):
        doc = json.loads(path.read_text())
        schemas[doc["schema"]] = doc
    return schemas


def validate(data: dict, schemas: dict[str, dict]) -> None:
    missing = [k for k in REQUIRED_KEYS if k not in data]
    if missing:
        raise ProfileError(f"missing keys: {missing}")
    if data["schema"] not in schemas:
        raise ProfileError(f"unknown schema {data['schema']!r}")
    allowed = set(schemas[data["schema"]]["fields"])
    method = data.get("method", "dom")
    if method not in METHODS:
        raise ProfileError(f"unknown method {method!r}")
    if method == "dom":
        extract = data.get("extract", {})
        if "item" not in extract or "fields" not in extract:
            raise ProfileError("extract needs 'item' and 'fields'")
        produced = set(extract["fields"]) | set(extract.get("context", {}))
    else:
        store = data.get("store", {})
        source = ("path",) if store.get("root") == "window" else ("require", "collection")
        if missing := [k for k in (*source, "fields") if k not in store]:
            raise ProfileError(f"store needs {missing}")
        produced = set(store["fields"])
    if unknown := produced - allowed:
        raise ProfileError(f"fields not in schema {data['schema']}: {sorted(unknown)}")
    identity = [n for n, f in schemas[data["schema"]]["fields"].items() if f.get("identity")]
    if not set(identity) <= produced:
        raise ProfileError(f"identity fields not extracted: {identity}")
    if unknown := set(data["canary"].get("fillRate", {})) - produced:
        raise ProfileError(f"canary checks fields that are never extracted: {sorted(unknown)}")


def load_profiles(directory: Path = PROFILES_DIR, schemas: dict[str, dict] | None = None) -> dict[str, Profile]:
    schemas = schemas if schemas is not None else load_schemas()
    profiles: dict[str, Profile] = {}
    for path in sorted(directory.glob("*.json")):
        raw = path.read_bytes()
        data = json.loads(raw)
        try:
            validate(data, schemas)
        except ProfileError as e:
            raise ProfileError(f"{path.name}: {e}") from e
        profile = Profile(data["profile"], int(data["profileVersion"]), data, hashlib.sha256(raw).hexdigest())
        if profile.key in profiles:
            raise ProfileError(f"{path.name}: duplicate profile {profile.key!r}")
        profiles[profile.key] = profile
    return profiles
