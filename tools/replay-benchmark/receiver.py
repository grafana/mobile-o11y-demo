"""Local benchmark sink, not Grafana storage. Forward pizza APIs to real local QuickPizza."""
import argparse
import base64
import hashlib
import http.client
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
args = parser.parse_args()
root = args.directory.resolve()
root.mkdir(parents=True, exist_ok=True)
lock = threading.Lock()
state = {"frames": [], "bodies": 0, "bodyBytes": 0, "run": None, "seen": {}}


def image_node(node):
    if node.get("tagName") == "img":
        return node
    for child in node.get("childNodes", []):
        found = image_node(child)
        if found is not None:
            return found
    return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, value, content_type="application/json"):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        # Current replay transport uses Content-Length. OTLP may use chunked encoding.
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks, size = [], 0
            while True:
                count = int(self.rfile.readline(1024).split(b";", 1)[0], 16)
                if count == 0:
                    while self.rfile.readline(8192) not in (b"\r\n", b"\n", b""):
                        pass
                    return b"".join(chunks)
                size += count
                if size > 16 * 1024 * 1024:
                    raise ValueError("body limit")
                chunks.append(self.rfile.read(count))
                if self.rfile.read(2) != b"\r\n":
                    raise ValueError("chunk terminator")
        count = int(self.headers.get("Content-Length", 0))
        if not 0 <= count <= 16 * 1024 * 1024:
            raise ValueError("body limit")
        return self.rfile.read(count)

    def do_GET(self):
        if self.path == "/_benchmark/latest":
            with lock:
                return self.reply(200, {"kind": "local-quickpizza-benchmark", "count": len(state["frames"]),
                    "frame": state["frames"][-1] if state["frames"] else None,
                    "bodyBytes": state["bodyBytes"], "bodies": state["bodies"]})
        self.forward(b"")

    def do_POST(self):
        try:
            body = self.read_body()
            if self.path == "/_benchmark/start":
                name = json.loads(body)["run"]
                if not re.fullmatch(r"[a-z0-9-]{1,48}", name):
                    raise ValueError("run name")
                with lock:
                    folder = root / name
                    if folder.exists():
                        return self.reply(409, {"error": "preserve existing evidence; choose a new run"})
                    folder.mkdir()
                    state.update(frames=[], bodies=0, bodyBytes=0, run=folder, seen={})
                return self.reply(200, {"kind": "local-quickpizza-benchmark"})
            if self.path.startswith("/collect/"):
                payload = json.loads(body)
                session = payload["meta"]["session"]["id"]
                assert session == self.headers.get("X-Faro-Session-Id")
                with lock:
                    folder = state["run"]
                    assert folder is not None
                    (folder / ("body-%04d.json" % state["bodies"])).write_bytes(body)
                    state["bodies"] += 1
                    state["bodyBytes"] += len(body)
                    for event in payload["events"]:
                        attrs = event.get("attributes", {})
                        if "event" not in attrs:
                            continue
                        rrweb = json.loads(attrs["event"])
                        key = (session, attrs["recording_id"], attrs["seq"])
                        digest = hashlib.sha256(attrs["event"].encode()).hexdigest()
                        if key in state["seen"]:
                            assert state["seen"][key] == digest
                            continue
                        state["seen"][key] = digest
                        if rrweb["type"] != 2:
                            continue
                        img = image_node(rrweb["data"]["node"])["attributes"]
                        frame = {"timestamp": rrweb["timestamp"], "session": session,
                            "recording": attrs["recording_id"], "screen": img["alt"],
                            "width": int(img["width"]), "height": int(img["height"]), "dataUri": img["src"]}
                        assert img["src"].startswith("data:image/")
                        state["frames"].append(frame)
                        (folder / ("frame-%03d.webp" % (len(state["frames"])-1))).write_bytes(base64.b64decode(img["src"].split(",", 1)[1], validate=True))
                    # Acknowledge only after the local file exists. This is not Grafana persistence.
                    (folder / "receipt-summary.json").write_text(json.dumps({"frames": len(state["frames"]),
                        "bodies": state["bodies"], "bodyBytes": state["bodyBytes"]}))
                return self.reply(202, {})
            if self.path.startswith("/otlp/"):
                # Consume local test telemetry; this benchmark makes no correlation/storage claim.
                return self.reply(200, b"", "application/x-protobuf")
            self.forward(body)
        except (ValueError, KeyError, AssertionError, TypeError) as error:
            self.reply(400, {"error": type(error).__name__})

    def forward(self, body):
        connection = http.client.HTTPConnection("127.0.0.1", 18003, timeout=10)
        try:
            headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection", "content-length", "transfer-encoding")}
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            self.reply(response.status, response.read(), response.getheader("Content-Type", "application/json"))
        except OSError:
            self.reply(503, {"error": "local pizza backend unavailable"})
        finally:
            connection.close()


server = ThreadingHTTPServer(("127.0.0.1", 18002), Handler)
print("Local benchmark receiver on 127.0.0.1:18002", flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()
