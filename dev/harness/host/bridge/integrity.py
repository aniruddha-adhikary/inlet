"""Identity, content hashing, record normalization and the canary check."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime

MAX_STRING = 64_000


def entity_id(app_id: str, schema: str, source_id: str) -> str:
    """Stable across runs and machines, so re-ingesting is idempotent."""
    return hashlib.sha256(f"{app_id}\x1f{schema}\x1f{source_id}".encode()).hexdigest()[:32]


def content_hash(record: dict) -> str:
    canonical = json.dumps(record, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def _coerce(value, spec: dict):
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > MAX_STRING:
        raise ValueError("expected a string")
    kind = spec["type"]
    if kind == "string":
        return value
    if kind == "enum":
        if value not in spec["values"]:
            raise ValueError(f"not one of {spec['values']}")
        return value
    if kind == "datetime":
        datetime.fromisoformat(value)
        return value
    raise ValueError(f"unknown type {kind}")


def normalize(record: dict, schema: dict) -> tuple[dict | None, list[str]]:
    """Project a raw extracted record onto the schema.

    A bad optional field is dropped (and reported); a bad or missing
    required field rejects the whole record.
    """
    if not isinstance(record, dict):
        return None, ["record is not an object"]
    clean: dict = {}
    problems: list[str] = []
    for name, spec in schema["fields"].items():
        try:
            clean[name] = _coerce(record.get(name), spec)
        except ValueError as e:
            problems.append(f"{name}: {e}")
            clean[name] = None
        if spec.get("required") and clean[name] is None:
            return None, problems + [f"{name}: required"]
    return clean, problems


def canary(rules: dict, view_stats: dict) -> tuple[bool, list[str]]:
    """Judge whether the profile still understands the page.

    view_stats describes everything the extractor saw on screen (not just
    the delta being ingested): {"total": n, "filled": {field: count}}.
    """
    failures: list[str] = []
    total = int(view_stats.get("total", 0))
    filled = view_stats.get("filled", {})
    if total < rules.get("minItems", 1):
        failures.append(f"items: saw {total}, need >= {rules.get('minItems', 1)}")
        return False, failures
    for field, minimum in rules.get("fillRate", {}).items():
        rate = int(filled.get(field, 0)) / total
        if rate < minimum:
            failures.append(f"{field}: fill rate {rate:.2f} < {minimum}")
    return not failures, failures
