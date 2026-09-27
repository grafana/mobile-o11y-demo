"""Loopback-only viewer; accepts test-result POSTs to one fixed local evidence file."""
import argparse
import functools
import json
import re
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    root = args.directory.resolve()
    (root / "index.html").write_text(Path(__file__).with_name("fair_viewer.html").read_text())

    class Handler(SimpleHTTPRequestHandler):
        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            self.send_header("Accept-Ranges", "bytes")
            super().end_headers()

        def do_POST(self):
            if self.path != "/checks":
                return self.send_error(404)
            size = int(self.headers.get("Content-Length", "0"))
            if not 1 <= size <= 2_000_000:
                return self.send_error(413)
            data = json.loads(self.rfile.read(size))
            (root / "browser-checks.json").write_text(json.dumps(data, indent=2))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"saved")

        def do_GET(self):
            requested = self.headers.get("Range")
            if not requested:
                return super().do_GET()
            path = Path(self.translate_path(self.path))
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested)
            if not path.is_file():
                return self.send_error(404)
            size = path.stat().st_size
            if not match:
                return self.send_error(416)
            start = int(match[1])
            end = min(int(match[2]) if match[2] else size-1, size-1)
            if start > end:
                return self.send_error(416)
            self.send_response(206)
            self.send_header("Content-Type", self.guess_type(str(path)))
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(end-start+1))
            self.end_headers()
            with path.open("rb") as stream:
                stream.seek(start)
                self.wfile.write(stream.read(end-start+1))

    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(root)))
    address = f"http://127.0.0.1:{server.server_port}"
    (root / "address.json").write_text(json.dumps({"url": address}))
    print(address, flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
