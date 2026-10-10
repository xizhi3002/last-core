import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("service", Path(__file__).with_name("service.py"))
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        service.DB_PATH = Path(self.temp.name) / "test.sqlite"
        with service.connect() as db:
            db.execute("INSERT INTO accounts(steamid) VALUES('a')")
            db.execute("INSERT INTO accounts(steamid) VALUES('b')")

    def tearDown(self):
        self.temp.cleanup()

    def test_no_client_identity_or_progression(self):
        run = service.create_run("a", 0)
        self.assertEqual(run["initial"]["meta"], {"power": 0})
        with self.assertRaises(ValueError):
            service.submit("b", run["run_id"], [])
        with self.assertRaises(PermissionError):
            service.identity("forged")

    def test_idempotent_atomic_settlement(self):
        run = service.create_run("a", 0)
        checked = {"valid": True, "wave": 15, "income": 400, "spent": 100}
        with patch.object(service, "verify_replay", return_value=checked):
            service.submit("a", run["run_id"], [])
            service.submit("a", run["run_id"], [])
        with service.connect() as db:
            self.assertEqual(db.execute("SELECT coins FROM accounts WHERE steamid='a'").fetchone()[0], 300)
        with self.assertRaises(ValueError):
            service.submit("a", run["run_id"], [{"changed": True}])

    def test_rank_tie_across_pages(self):
        with service.connect() as db:
            for i in range(60):
                db.execute("INSERT INTO scores VALUES(?,?,?,?,?,0)", (str(i), 0, service.RULES["version"], 100, str(i)))
        self.assertTrue(all(row["rank"] == 1 for row in service.leaderboard(0, 50)))
        self.assertEqual(service.leaderboard(1), [])

    def test_rejected_run_cannot_retry(self):
        run = service.create_run("a", 0)
        with patch.object(service, "verify_replay", side_effect=ValueError("invalid")):
            with self.assertRaises(ValueError):
                service.submit("a", run["run_id"], [])
        with self.assertRaises(ValueError):
            service.submit("a", run["run_id"], [])

    def test_offline_records_not_accepted(self):
        with self.assertRaises(ValueError):
            service.submit("a", "offline-fake-id", [])


if __name__ == "__main__":
    unittest.main()
