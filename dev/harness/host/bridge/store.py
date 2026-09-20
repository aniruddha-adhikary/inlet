"""SQLite store. This file is the contract with the (future) Swift donor:
it reads rows where content_hash != donated_hash, donates them to Spotlight,
then writes donated_hash back."""

from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime
from pathlib import Path

QUARANTINE_AFTER = 3

DDL = """
CREATE TABLE IF NOT EXISTS entities (
    id              TEXT PRIMARY KEY,
    app_id          TEXT NOT NULL,
    schema          TEXT NOT NULL,
    source_id       TEXT NOT NULL,
    payload         TEXT NOT NULL,
    content_hash    TEXT NOT NULL,
    revision        INTEGER NOT NULL DEFAULT 1,
    profile_key     TEXT NOT NULL,
    profile_sha     TEXT NOT NULL,
    first_seen      TEXT NOT NULL,
    last_seen       TEXT NOT NULL,
    donated_hash    TEXT
);
CREATE INDEX IF NOT EXISTS entities_pending ON entities (app_id) WHERE donated_hash IS NOT content_hash;

CREATE TABLE IF NOT EXISTS batches (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at     TEXT NOT NULL,
    profile_key     TEXT NOT NULL,
    profile_sha     TEXT NOT NULL,
    app_version     TEXT,
    fingerprint     TEXT,
    seen            INTEGER NOT NULL,
    inserted        INTEGER NOT NULL,
    updated         INTEGER NOT NULL,
    unchanged       INTEGER NOT NULL,
    rejected        INTEGER NOT NULL,
    canary_ok       INTEGER NOT NULL,
    detail          TEXT
);

CREATE TABLE IF NOT EXISTS profile_state (
    profile_key         TEXT PRIMARY KEY,
    status              TEXT NOT NULL DEFAULT 'active',
    consecutive_fails   INTEGER NOT NULL DEFAULT 0,
    fingerprint         TEXT,
    fingerprint_changes INTEGER NOT NULL DEFAULT 0,
    last_ok_at          TEXT
);
"""


def now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class Store:
    def __init__(self, path: Path | str):
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(DDL)

    # -- profile health -------------------------------------------------

    def profile_status(self, profile_key: str) -> str:
        row = self.db.execute("SELECT status FROM profile_state WHERE profile_key=?", (profile_key,)).fetchone()
        return row["status"] if row else "active"

    def record_canary(self, profile_key: str, ok: bool, fingerprint: str | None) -> dict:
        """Returns {"status", "drift"}; drift is True when the DOM shape changed."""
        self.db.execute("INSERT OR IGNORE INTO profile_state (profile_key) VALUES (?)", (profile_key,))
        row = self.db.execute("SELECT * FROM profile_state WHERE profile_key=?", (profile_key,)).fetchone()
        drift = bool(fingerprint and row["fingerprint"] and fingerprint != row["fingerprint"])
        fails = 0 if ok else row["consecutive_fails"] + 1
        status = "quarantined" if fails >= QUARANTINE_AFTER else row["status"]
        self.db.execute(
            """UPDATE profile_state SET status=?, consecutive_fails=?,
                   fingerprint=COALESCE(?, fingerprint),
                   fingerprint_changes=fingerprint_changes+?,
                   last_ok_at=CASE WHEN ? THEN ? ELSE last_ok_at END
               WHERE profile_key=?""",
            (status, fails, fingerprint if ok else None, int(drift), int(ok), now(), profile_key),
        )
        return {"status": status, "drift": drift}

    def release(self, profile_key: str) -> bool:
        cur = self.db.execute(
            "UPDATE profile_state SET status='active', consecutive_fails=0 WHERE profile_key=?", (profile_key,)
        )
        return cur.rowcount > 0

    # -- entities -------------------------------------------------------

    def upsert(self, entity_id: str, app_id: str, schema: str, record: dict, digest: str, profile) -> str:
        ts = now()
        row = self.db.execute("SELECT content_hash FROM entities WHERE id=?", (entity_id,)).fetchone()
        if row is None:
            self.db.execute(
                """INSERT INTO entities (id, app_id, schema, source_id, payload, content_hash,
                       profile_key, profile_sha, first_seen, last_seen)
                   VALUES (?,?,?,?,?,?,?,?,?,?)""",
                (
                    entity_id,
                    app_id,
                    schema,
                    record["sourceId"],
                    json.dumps(record, ensure_ascii=False),
                    digest,
                    profile.key,
                    profile.checksum,
                    ts,
                    ts,
                ),
            )
            return "inserted"
        if row["content_hash"] == digest:
            self.db.execute("UPDATE entities SET last_seen=? WHERE id=?", (ts, entity_id))
            return "unchanged"
        self.db.execute(
            """UPDATE entities SET payload=?, content_hash=?, revision=revision+1,
                   profile_key=?, profile_sha=?, last_seen=? WHERE id=?""",
            (json.dumps(record, ensure_ascii=False), digest, profile.key, profile.checksum, ts, entity_id),
        )
        return "updated"

    def log_batch(self, profile, batch: dict, counts: dict, canary_ok: bool, detail: list[str]) -> int:
        cur = self.db.execute(
            """INSERT INTO batches (received_at, profile_key, profile_sha, app_version, fingerprint,
                   seen, inserted, updated, unchanged, rejected, canary_ok, detail)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                now(),
                profile.key,
                profile.checksum,
                batch.get("appVersion"),
                batch.get("fingerprint"),
                counts["seen"],
                counts["inserted"],
                counts["updated"],
                counts["unchanged"],
                counts["rejected"],
                int(canary_ok),
                json.dumps(detail) if detail else None,
            ),
        )
        return cur.lastrowid

    # -- reporting ------------------------------------------------------

    def summary(self) -> dict:
        q = self.db.execute
        return {
            "entities": [
                dict(r)
                for r in q(
                    """SELECT app_id, schema, COUNT(*) AS total,
                          SUM(donated_hash IS NOT content_hash) AS pending_donation
                   FROM entities GROUP BY app_id, schema"""
                )
            ],
            "profiles": [dict(r) for r in q("SELECT * FROM profile_state")],
            "recent_batches": [dict(r) for r in q("SELECT * FROM batches ORDER BY id DESC LIMIT 5")],
        }

    def verify(self) -> list[str]:
        """Re-hash every payload; a mismatch means the row was altered outside the bridge."""
        from .integrity import content_hash

        return [
            r["id"]
            for r in self.db.execute("SELECT id, payload, content_hash FROM entities")
            if content_hash(json.loads(r["payload"])) != r["content_hash"]
        ]
