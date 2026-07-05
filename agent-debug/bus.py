#!/usr/bin/env python3
"""Tiny LAN message bus for agent-to-agent chat over the local wifi.

Runs on Mac #1. Both agents talk to it over HTTP (curl) — no GitHub round-trip.
Messages persist to bus.jsonl so a restart keeps history.

Endpoints:
  POST /send    body=raw text, header X-Agent: claude|codex   -> {"seq": N}
  GET  /read                                                  -> full transcript (text)
  GET  /since/<seq>                                           -> JSON messages after <seq>
  GET  /wait/<seq>?agent=<me>&secs=<n>                        -> long-poll: block until a
                                                                PEER message with seq><seq>,
                                                                then return it as JSON (or [] on timeout)
  GET  /health                                               -> "ok"
"""
import json
import os
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "bus.jsonl")

_lock = threading.Lock()
_msgs = []  # list of {seq, ts, agent, msg}


def _load():
    if not os.path.exists(LOG):
        return
    with open(LOG, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    _msgs.append(json.loads(line))
                except ValueError:
                    pass


def _append(agent, msg):
    with _lock:
        seq = (_msgs[-1]["seq"] + 1) if _msgs else 1
        rec = {
            "seq": seq,
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "agent": agent,
            "msg": msg,
        }
        _msgs.append(rec)
        with open(LOG, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return rec


def _since(seq):
    with _lock:
        return [m for m in _msgs if m["seq"] > seq]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # quiet

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        query = {}
        if "?" in self.path:
            for kv in self.path.split("?", 1)[1].split("&"):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    query[k] = v

        if path == "/health":
            return self._send(200, "ok")

        if path == "/read":
            with _lock:
                lines = [f'[{m["ts"]}] {m["agent"]}: {m["msg"]}' for m in _msgs]
            return self._send(200, "\n".join(lines) + ("\n" if lines else ""))

        if path.startswith("/since/"):
            try:
                seq = int(path[len("/since/"):])
            except ValueError:
                return self._send(400, "bad seq")
            return self._send(200, json.dumps(_since(seq), ensure_ascii=False),
                              "application/json; charset=utf-8")

        if path.startswith("/wait/"):
            try:
                seq = int(path[len("/wait/"):])
            except ValueError:
                return self._send(400, "bad seq")
            me = query.get("agent", "")
            secs = min(int(query.get("secs", "25")), 60)
            deadline = time.time() + secs
            while time.time() < deadline:
                new = [m for m in _since(seq) if m["agent"] != me]
                if new:
                    return self._send(200, json.dumps(new, ensure_ascii=False),
                                      "application/json; charset=utf-8")
                time.sleep(0.5)
            return self._send(200, "[]", "application/json; charset=utf-8")

        return self._send(404, "not found")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/send":
            return self._send(404, "not found")
        agent = self.headers.get("X-Agent", "").strip()
        if agent not in ("claude", "codex"):
            return self._send(400, "set X-Agent: claude|codex")
        length = int(self.headers.get("Content-Length", "0"))
        msg = self.rfile.read(length).decode("utf-8", "replace").rstrip("\n")
        rec = _append(agent, msg)
        return self._send(200, json.dumps({"seq": rec["seq"], "ts": rec["ts"]}),
                          "application/json; charset=utf-8")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    _load()
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"bus listening on 0.0.0.0:{port} — {len(_msgs)} msg loaded", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
