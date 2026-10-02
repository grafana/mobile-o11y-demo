"""Loopback-only MP4 smoke sink. Saved receipts are local evidence, not Grafana storage."""
import argparse
from email import policy
from email.parser import BytesParser
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading

MAX_BODY = 16 * 1024 * 1024


def attributes(items):
    return {item["key"]: item["value"].get("stringValue") for item in items}


def recording_events(payload):
    for resource in payload.get("resourceLogs", []):
        session = attributes(resource.get("resource", {}).get("attributes", []))["session.id"]
        for scope in resource.get("scopeLogs", []):
            for record in scope.get("logRecords", []):
                if record.get("eventName") != "faro.session_recording.event":
                    continue
                attrs = attributes(record["attributes"])
                event = json.loads(attrs["event"])
                yield dict(event, session=session, recording=attrs["recording_id"],
                           generation=int(attrs["gen"]), sequence=int(attrs["seq"]))


def multipart(content_type, body):
    message = BytesParser(policy=policy.default).parsebytes(
        b"Content-Type: " + content_type.encode("ascii") + b"\r\nMIME-Version: 1.0\r\n\r\n" + body)
    if not message.is_multipart():
        raise ValueError("invalid multipart")
    parts = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name not in ("payload", "clip") or name in parts:
            raise ValueError("unexpected multipart part")
        parts[name] = (part, part.get_payload(decode=True))
    if set(parts) != {"payload", "clip"}:
        raise ValueError("missing multipart part")
    if parts["payload"][0].get_content_type() != "application/json" or parts["clip"][0].get_content_type() != "video/mp4":
        raise ValueError("unexpected part MIME type")
    return json.loads(parts["payload"][1]), parts["clip"][0].get_filename(), parts["clip"][1]


def serve(directory, port=18002):
    directory.mkdir(parents=True, exist_ok=False)
    lock = threading.Lock()
    receipts, seen = [], {}
    telemetry_requests = []
    (directory / "telemetry").mkdir()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, value, mime="application/json"):
            body = value if isinstance(value, bytes) else json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def read_body(self):
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                chunks, size = [], 0
                while True:
                    length = int(self.rfile.readline(1024).split(b";", 1)[0], 16)
                    if length == 0:
                        while self.rfile.readline(8192) not in (b"\r\n", b"\n", b""):
                            pass
                        return b"".join(chunks)
                    size += length
                    if length < 0 or size > MAX_BODY:
                        raise ValueError("body limit")
                    chunk = self.rfile.read(length)
                    if len(chunk) != length or self.rfile.read(2) != b"\r\n":
                        raise ValueError("incomplete chunk")
                    chunks.append(chunk)
            length = int(self.headers.get("Content-Length", 0))
            if not 0 <= length <= MAX_BODY:
                raise ValueError("body limit")
            body = self.rfile.read(length)
            if len(body) != length:
                raise ValueError("incomplete body")
            return body

        def do_GET(self):
            if self.path == "/_test/receipts":
                with lock:
                    return self.reply(200, list(telemetry_requests))
            if self.path.startswith("/_test/body/"):
                key = self.path.removeprefix("/_test/body/")
                if not key.isascii() or not key.isdecimal() or len(key) > 10:
                    return self.reply(400, {})
                index = int(key)
                with lock:
                    if index >= len(telemetry_requests):
                        return self.reply(404, {})
                    file = directory / telemetry_requests[index]["bodyFile"]
                    return self.reply(200, file.read_bytes(), "application/octet-stream")
            if self.path == "/_automatic/receipts":
                with lock:
                    return self.reply(200, receipts)
            if self.path.startswith("/_automatic/clip/"):
                key = self.path.removeprefix("/_automatic/clip/")
                if not key.isdecimal():
                    return self.reply(400, {})
                file = directory / ("clip-%04d.mp4" % int(key))
                if not file.is_file():
                    return self.reply(404, {})
                return self.reply(200, file.read_bytes(), "video/mp4")
            self.forward(b"")

        def do_POST(self):
            try:
                body = self.read_body()
                if self.path.startswith("/otlp/"):
                    # Retain the exact SDK export for the teardown drain, without a storage claim.
                    if not self.headers.get("X-Faro-Session-Id"):
                        with lock:
                            index = len(telemetry_requests)
                            relative = "telemetry/%04d.bin" % index
                            (directory / relative).write_bytes(body)
                            telemetry_requests.append(dict(requestIndex=index, bodyFile=relative,
                                path=self.path, status=200, forwarded=False, bytes=len(body),
                                contentType=self.headers.get("Content-Type"),
                                contentEncoding=self.headers.get("Content-Encoding"),
                                sha256=hashlib.sha256(body).hexdigest()))
                            (directory / "telemetry-requests.json").write_text(json.dumps(telemetry_requests, indent=2))
                        return self.reply(200, b"", "application/x-protobuf")
                    mime = self.headers.get("Content-Type", "")
                    if mime.startswith("multipart/form-data;"):
                        payload, name, clip = multipart(mime, body)
                    elif mime.startswith("application/json"):
                        payload, name, clip = json.loads(body), None, None
                    else:
                        raise ValueError("unexpected replay request MIME type")
                    events = list(recording_events(payload))
                    if len(events) != 1:
                        raise ValueError("expected one recording event per request")
                    event = events[0]
                    session = self.headers["X-Faro-Session-Id"]
                    if event["session"] != session:
                        raise ValueError("session mismatch")
                    is_video = event["type"] == 5 and event["data"].get("kind") == "mobile-video"
                    if is_video:
                        if not clip or len(clip) < 12 or clip[4:8] != b"ftyp" or event["data"]["file"] != name:
                            raise ValueError("invalid MP4 card/file pairing")
                    elif event["type"] != 4 or clip is not None:
                        raise ValueError("expected Meta or mobile-video")
                    key = (session, event["recording"], event["sequence"])
                    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode() + (clip or b"")).hexdigest()
                    with lock:
                        if key in seen:
                            if seen[key] != digest:
                                raise ValueError("retry changed immutable identity")
                            return self.reply(200, {})
                        index = len(receipts)
                        receipt = {"index": index, "status": 200, "bytes": len(body), "path": self.path,
                                   "session": session, "events": [event], "multipart": clip is not None}
                        if is_video:
                            saved = directory / ("clip-%04d.mp4" % index)
                            saved.write_bytes(clip)
                            receipt.update(clipUrl=f"http://127.0.0.1:{port}/_automatic/clip/{index}",
                                           clipBytes=len(clip), clipSha256=hashlib.sha256(clip).hexdigest())
                        (directory / ("payload-%04d.json" % index)).write_text(json.dumps(payload, indent=2))
                        receipts.append(receipt)
                        seen[key] = digest
                        (directory / "receipts.json").write_text(json.dumps(receipts, indent=2))
                    # Acknowledge only after the masked clip and receipt have been written locally.
                    return self.reply(200, {})
                self.forward(body)
            except (ValueError, KeyError, TypeError, UnicodeError) as error:
                self.reply(400, {"error": type(error).__name__})

        def forward(self, body):
            connection = http.client.HTTPConnection("127.0.0.1", 18003, timeout=10)
            try:
                headers = {key: value for key, value in self.headers.items()
                           if key.lower() not in ("host", "connection", "content-length", "transfer-encoding")}
                connection.request(self.command, self.path, body, headers)
                response = connection.getresponse()
                self.reply(response.status, response.read(), response.getheader("Content-Type", "application/json"))
            except OSError:
                self.reply(503, {"error": "local pizza backend unavailable"})
            finally:
                connection.close()

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Local MP4 smoke receiver on 127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--port", type=int, default=18002)
    args = parser.parse_args()
    serve(args.directory.resolve(), args.port)
