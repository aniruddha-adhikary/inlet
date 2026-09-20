import unittest

from bridge import integrity
from bridge.profiles import ProfileError, load_profiles, load_schemas, validate
from bridge.server import ingest
from bridge.store import QUARANTINE_AFTER, Store


def batch(items, **over):
    filled = {}
    for rec in items:
        for k, v in rec.items():
            if v is not None:
                filled[k] = filled.get(k, 0) + 1
    base = {
        "profile": "demo-chat",
        "profileVersion": 1,
        "fingerprint": "aaaa",
        "items": items,
        "viewStats": {"total": len(items), "filled": filled},
    }
    return base | over


def msg(i, body="hi"):
    return {
        "sourceId": f"m{i}",
        "sender": "Flare",
        "direction": "incoming",
        "body": body,
        "sentAt": "2026-09-19T18:02:00+05:30",
        "conversationId": "c1",
        "conversationName": "Flare",
    }


class IngestTest(unittest.TestCase):
    def setUp(self):
        self.schemas = load_schemas()
        self.profiles = load_profiles(schemas=self.schemas)
        self.store = Store(":memory:")

    def run_batch(self, b):
        return ingest(self.store, self.profiles, self.schemas, b)

    def test_shipped_profiles_validate(self):
        self.assertIn("whatsapp-web@1", self.profiles)

    def test_idempotent_then_edit_bumps_revision(self):
        self.assertEqual(self.run_batch(batch([msg(1), msg(2)]))[1]["inserted"], 2)
        self.assertEqual(self.run_batch(batch([msg(1), msg(2)]))[1]["unchanged"], 2)
        self.assertEqual(self.run_batch(batch([msg(1, "edited"), msg(2)]))[1]["updated"], 1)
        rev = self.store.db.execute("SELECT revision FROM entities WHERE source_id='m1'").fetchone()[0]
        self.assertEqual(rev, 2)

    def test_bad_enum_is_dropped_but_record_kept(self):
        rec = msg(1) | {"direction": "sideways"}
        clean, problems = integrity.normalize(rec, self.schemas["messages.message"])
        self.assertIsNone(clean["direction"])
        self.assertTrue(problems)

    def test_missing_identity_rejects_record(self):
        items = [msg(i) for i in range(1, 20)] + [msg(99) | {"sourceId": None}]
        status, body = self.run_batch(
            batch(items, viewStats={"total": 20, "filled": {"sourceId": 20, "sender": 20, "sentAt": 20, "body": 20}})
        )
        self.assertEqual((status, body["rejected"], body["inserted"]), (200, 1, 19))

    def test_canary_failure_stores_nothing_and_quarantines(self):
        broken = [msg(i) | {"sender": None, "sentAt": None} for i in range(3)]
        for _ in range(QUARANTINE_AFTER):
            status, body = self.run_batch(batch(broken))
            self.assertEqual(status, 422)
        self.assertEqual(body["status"], "quarantined")
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM entities").fetchone()[0], 0)
        self.assertEqual(self.run_batch(batch([msg(1)]))[0], 423)
        self.store.release("demo-chat@1")
        self.assertEqual(self.run_batch(batch([msg(1)]))[0], 200)

    def test_verify_detects_tampering(self):
        self.run_batch(batch([msg(1)]))
        self.assertEqual(self.store.verify(), [])
        self.store.db.execute("UPDATE entities SET payload=replace(payload, 'hi', 'bye')")
        self.assertEqual(len(self.store.verify()), 1)

    def test_profile_with_unknown_field_is_refused(self):
        data = dict(self.profiles["demo-chat@1"].data)
        data["extract"] = {"item": "li", "fields": {"sourceId": {}, "mood": {}}}
        with self.assertRaises(ProfileError):
            validate(data, self.schemas)


if __name__ == "__main__":
    unittest.main()
