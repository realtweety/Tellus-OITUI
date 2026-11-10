#!/usr/bin/env python3
"""Serves one big file slowly, so a browser download on the phone lasts long enough to watch (browser downloads research, 0.3.5).

The phone downloads http://<this PC>:<port>/<name> over your local network. The file is generated on the fly (the same 64 KiB of
pseudo-random bytes repeated), so nothing is stored on disk. It is sent as an attachment (Content-Disposition) with a known
Content-Length, so a browser treats it as a download and can show a percentage.

Usage (repo root, on the PC):
    python3 tools/throttle_server.py                       # 400 MB at 1 MB/s (about 7 minutes) on port 8099
    python3 tools/throttle_server.py --size-mb 200 --rate-mb 0.5 --port 8099 --name test.bin

Notes. Plain HTTP: if a browser refuses an http:// link, try the same link in Safari. The phone and the PC must be on the same
network, and the PC's firewall must allow the port. Range requests are honoured (a paused download that resumes asks for a range).
Ctrl+C stops it. Nothing here touches the phone or the repo.
"""
import argparse
import os
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHUNK = os.urandom(64 * 1024)


def lan_address():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))   # no packet is sent; this only picks the interface the OS would use
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    size = 0
    rate = 0.0
    name = "test.bin"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    def _range(self):
        header = self.headers.get("Range")
        if not header or not header.startswith("bytes="):
            return 0, self.size - 1, False
        try:
            start_text, end_text = header[6:].split("-", 1)
            start = int(start_text) if start_text else max(0, self.size - int(end_text))
            end = int(end_text) if end_text and start_text else self.size - 1
        except ValueError:
            return 0, self.size - 1, False
        return max(0, start), min(end, self.size - 1), True

    def _send(self, head_only):
        if self.path.split("?", 1)[0].lstrip("/") != self.name:
            self.send_error(404, "the file is /" + self.name)
            return
        start, end, partial = self._range()
        if start > end:
            self.send_error(416)
            return
        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % self.name)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, self.size))
        self.end_headers()
        if head_only:
            return
        sent, begun = 0, time.monotonic()
        try:
            while sent < length:
                piece = CHUNK[: min(len(CHUNK), length - sent)]
                self.wfile.write(piece)
                sent += len(piece)
                ahead = sent / self.rate - (time.monotonic() - begun)   # seconds we are ahead of the wanted rate
                if ahead > 0:
                    time.sleep(ahead)
        except (BrokenPipeError, ConnectionResetError):
            self.log_message("client closed the connection after %.1f MB", sent / 1e6)

    def do_GET(self):
        self._send(False)

    def do_HEAD(self):
        self._send(True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--size-mb", type=float, default=400.0)
    parser.add_argument("--rate-mb", type=float, default=1.0, help="megabytes per second")
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--name", default="test.bin")
    args = parser.parse_args()
    Handler.size = int(args.size_mb * 1e6)
    Handler.rate = args.rate_mb * 1e6
    Handler.name = args.name
    print("Serving %.0f MB at %.2f MB/s (about %.0f s)." % (args.size_mb, args.rate_mb, args.size_mb / args.rate_mb))
    print("Open this on the phone:  http://%s:%d/%s" % (lan_address(), args.port, args.name))
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
