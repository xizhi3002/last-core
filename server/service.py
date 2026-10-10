"""Development trusted-score service. No public bind or Steam writes by default.

The identity adapter verifies Steam tickets and ownership. Authoritative runs use
server-selected seeds and server-owned progression, then the SAME Godot simulation
replays every command. Offline save files and claimed scores are never trusted.
Production still requires deployment, rate limiting and Steam acceptance testing.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
RULES = json.loads((ROOT / "data/rules.json").read_text(encoding="utf-8"))
BOARD_NAMES = [f"endless_{m['width']}x{m['height']}" for m in RULES["maps"]]
DB_PATH = Path(os.environ.get("LC_DB", str(ROOT / "build/service.sqlite")))
GODOT = os.environ.get("LC_GODOT", "godot")
APP_ID = int(os.environ.get("STEAM_APP_ID", "0"))
KEY = os.environ.get("STEAM_PUBLISHER_KEY", "")


class Connection(sqlite3.Connection):
    def __exit__(self, *args):
        try:
            return super().__exit__(*args)
        finally:
            self.close()


def connect():
    db = sqlite3.connect(DB_PATH, timeout=30, factory=Connection)
    db.row_factory = sqlite3.Row
    db.executescript('''
    CREATE TABLE IF NOT EXISTS accounts(steamid TEXT PRIMARY KEY, coins INTEGER NOT NULL DEFAULT 0, meta TEXT NOT NULL DEFAULT '{"power":0}');
    CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY, steamid TEXT NOT NULL, expires REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, steamid TEXT NOT NULL, initial TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open', result TEXT, digest TEXT, created REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS scores(steamid TEXT NOT NULL, map INTEGER NOT NULL, version TEXT NOT NULL, wave INTEGER NOT NULL, run_id TEXT NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(steamid,map,version));
    ''')
    return db


def steam_api(interface, method, params, version="v1", post=False):
    if not APP_ID or not KEY:
        raise ValueError("Steam production credentials are not configured")
    values = urllib.parse.urlencode({"key": KEY, "appid": APP_ID, **params}).encode()
    url = f"https://partner.steam-api.com/{interface}/{method}/{version}/"
    req = urllib.request.Request(url if post else url + "?" + values.decode(), data=values if post else None)
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.load(response)


def authenticate(ticket):
    if not isinstance(ticket, str) or not 20 <= len(ticket) <= 8192 or any(c not in "0123456789abcdefABCDEF" for c in ticket):
        raise ValueError("Malformed ticket")
    result = steam_api("ISteamUserAuth", "AuthenticateUserTicket", {"ticket": ticket, "identity": "lastcore"})
    auth = result.get("response", {}).get("params", {})
    if auth.get("result") != "OK" or auth.get("vacbanned") or auth.get("publisherbanned"):
        raise ValueError("Steam ticket rejected")
    steamid = str(auth["steamid"])
    owned = steam_api("ISteamUser", "CheckAppOwnership", {"steamid": steamid}, "v4")
    if not owned.get("appownership", {}).get("ownsapp", False):
        raise ValueError("Game ownership required")
    token = secrets.token_urlsafe(32)
    with connect() as db:
        db.execute("INSERT OR IGNORE INTO accounts(steamid) VALUES(?)", (steamid,))
        db.execute("INSERT INTO sessions VALUES(?,?,?)", (hashlib.sha256(token.encode()).hexdigest(), steamid, time.time() + 3600))
    return {"token": token, "steamid": steamid, "expires_in": 3600}


def identity(token):
    with connect() as db:
        row = db.execute("SELECT steamid FROM sessions WHERE token=? AND expires>?", (hashlib.sha256(token.encode()).hexdigest(), time.time())).fetchone()
    if row is None:
        raise PermissionError("Expired or invalid session")
    return row["steamid"]


def create_run(steamid, map_id):
    if type(map_id) is not int or map_id not in range(5):
        raise ValueError("Invalid map")
    with connect() as db:
        active = db.execute("SELECT id FROM runs WHERE steamid=? AND status IN ('open','checking')", (steamid,)).fetchone()
        if active:
            raise ValueError("Finish the existing ranked run first")
        account = db.execute("SELECT meta FROM accounts WHERE steamid=?", (steamid,)).fetchone()
        initial = {"version": RULES["version"], "seed": secrets.randbelow(2_000_000_000), "map": map_id,
                   "meta": json.loads(account["meta"]), "loadout": [t["id"] for t in RULES["towers"][:6]]}
        run_id = secrets.token_urlsafe(24)
        db.execute("INSERT INTO runs(id,steamid,initial,created) VALUES(?,?,?,?)", (run_id, steamid, json.dumps(initial), time.time()))
    return {"run_id": run_id, "initial": initial, "verified": False}


def verify_replay(initial, commands):
    if not isinstance(commands, list) or len(commands) > 50000:
        raise ValueError("Invalid command budget")
    for c in commands:
        if not isinstance(c, dict) or type(c.get("tick")) is not int or not isinstance(c.get("args"), list):
            raise ValueError("Malformed replay")
    with tempfile.TemporaryDirectory(prefix="lc-replay-") as temp:
        job = Path(temp) / "job.json"
        job.write_text(json.dumps({"initial": initial, "commands": commands}), encoding="utf-8")
        result = subprocess.run([GODOT, "--headless", "--path", str(ROOT), "--script", "res://scripts/replay_verify.gd", "--", str(job)],
                                capture_output=True, text=True, timeout=180, check=False)
    lines = [line for line in result.stdout.splitlines() if line.startswith('{"')]
    if result.returncode or not lines:
        raise ValueError("Replay verification failed")
    checked = json.loads(lines[-1])
    if not checked.get("valid") or type(checked.get("wave")) is not int or not 0 <= checked["wave"] <= 2_147_483_647:
        raise ValueError("Unverified or unsupported score encoding")
    return checked


def submit(steamid, run_id, commands):
    digest = hashlib.sha256(json.dumps(commands, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT * FROM runs WHERE id=? AND steamid=?", (run_id, steamid)).fetchone()
        if not row:
            raise ValueError("Unknown expedition")
        if row["status"] == "verified":
            if row["digest"] != digest:
                raise ValueError("Conflicting submission")
            return json.loads(row["result"])
        if row["status"] != "open":
            raise ValueError("Expedition is sealed or being checked")
        db.execute("UPDATE runs SET status='checking',digest=? WHERE id=?", (digest, run_id))
        initial = json.loads(row["initial"])
    try:
        result = verify_replay(initial, commands)
    except Exception:
        with connect() as db:
            db.execute("UPDATE runs SET status='rejected' WHERE id=?", (run_id,))
        raise
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("UPDATE runs SET status='verified',result=? WHERE id=?", (json.dumps(result), run_id))
        db.execute("UPDATE accounts SET coins=coins+? WHERE steamid=?", (max(0, result["income"] - result["spent"]), steamid))
        db.execute('''INSERT INTO scores(steamid,map,version,wave,run_id) VALUES(?,?,?,?,?)
                   ON CONFLICT(steamid,map,version) DO UPDATE SET wave=excluded.wave,run_id=excluded.run_id,uploaded=0 WHERE excluded.wave>scores.wave''',
                   (steamid, initial["map"], initial["version"], result["wave"], run_id))
    return result


def leaderboard(map_id, offset=0):
    if map_id not in range(5) or not 0 <= offset <= 1000000:
        raise ValueError("Invalid page")
    with connect() as db:
        # RANK computed over the full map BEFORE pagination, so page-boundary ties work.
        rows = db.execute('''SELECT * FROM (SELECT steamid,wave,run_id,RANK() OVER(ORDER BY wave DESC) AS rank
                FROM scores WHERE map=? AND version=?) ORDER BY wave DESC,steamid LIMIT 50 OFFSET ?''',
                          (map_id, RULES["version"], offset)).fetchall()
    return [dict(r) for r in rows]


def upload_pending():
    """Explicit administrative action only, after Trusted boards are configured."""
    boards = json.loads(os.environ.get("STEAM_BOARD_IDS", "{}"))
    if len(boards) != 5:
        raise ValueError("Five Steam leaderboard IDs required")
    with connect() as db:
        rows = db.execute("SELECT * FROM scores WHERE uploaded=0").fetchall()
    for row in rows:
        steam_api("ISteamLeaderboards", "SetLeaderboardScore", {"leaderboardid": boards[BOARD_NAMES[row["map"]]],
                   "steamid": row["steamid"], "score": row["wave"], "scoremethod": "KeepBest"}, post=True)
        with connect() as db:
            db.execute("UPDATE scores SET uploaded=1 WHERE steamid=? AND map=? AND version=? AND wave=?", (row["steamid"], row["map"], row["version"], row["wave"]))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log bearer tokens or Steam tickets.

    def respond(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 8_000_000:
                raise ValueError("Invalid body size")
            data = json.loads(self.rfile.read(length))
            if self.path == "/v1/auth":
                return self.respond(200, authenticate(data.get("ticket")))
            steamid = identity(self.headers.get("Authorization", "").removeprefix("Bearer "))
            if self.path == "/v1/runs":
                return self.respond(201, create_run(steamid, data.get("map")))
            if self.path == "/v1/submit":
                return self.respond(200, submit(steamid, data.get("run_id"), data.get("commands")))
            self.respond(404, {"error": "not found"})
        except PermissionError as exc:
            self.respond(401, {"error": str(exc)})
        except (ValueError, KeyError, TypeError) as exc:
            self.respond(400, {"error": str(exc)})
        except Exception:
            self.respond(503, {"error": "verification unavailable"})

    def do_GET(self):
        try:
            url = urllib.parse.urlparse(self.path)
            if url.path == "/health":
                return self.respond(200, {"status": "development", "rules": RULES["version"], "steam_configured": bool(APP_ID and KEY)})
            if url.path == "/v1/leaderboard":
                q = urllib.parse.parse_qs(url.query)
                return self.respond(200, {"entries": leaderboard(int(q.get("map", [0])[0]), int(q.get("offset", [0])[0]))})
            self.respond(404, {"error": "not found"})
        except (ValueError, KeyError):
            self.respond(400, {"error": "invalid query"})


if __name__ == "__main__":
    connect().close()
    print("LAST CORE development verification service: http://127.0.0.1:8765")
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
