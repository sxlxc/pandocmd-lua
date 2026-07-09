#!/usr/bin/env python3

import base64
import functools
import hashlib
import http.server
import json
import socket
import struct
import sys
import threading
import urllib.parse


# Match the LiveReload official-7 JSON protocol also used by Hugo.
LIVE_RELOAD_PROTOCOL = "http://livereload.com/protocols/official-7"
WEBSOCKET_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class LiveReloadHub:
    def __init__(self):
        self.clients = set()
        self.lock = threading.Lock()

    def register(self, client):
        with self.lock:
            self.clients.add(client)

    def unregister(self, client):
        with self.lock:
            self.clients.discard(client)

    def broadcast_reload(self, path):
        message = {
            "command": "reload",
            "path": path,
            "originalPath": "",
            "liveCSS": True,
            "liveImg": True,
        }
        text = json.dumps(message, separators=(",", ":"))

        with self.lock:
            clients = list(self.clients)

        print(
            "LiveReload: broadcasting reload for {} to {} client(s)".format(path, len(clients)),
            file=sys.stderr,
            flush=True,
        )

        delivered = 0
        for client in clients:
            if client.send_text(text):
                delivered += 1
            else:
                self.unregister(client)
                client.close()

        return delivered


class LiveReloadClient:
    def __init__(self, handler):
        self.handler = handler
        self.socket = handler.connection
        self.send_lock = threading.Lock()
        self.open = True

    def read_loop(self):
        while self.open:
            frame = self.read_frame()
            if frame is None:
                break

            opcode, payload = frame
            if opcode == 0x8:
                break
            if opcode == 0x9:
                self.send_frame(0xA, payload)
                continue
            if opcode != 0x1:
                continue

            try:
                message = json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue

            if message.get("command") == "hello":
                self.send_json({
                    "command": "hello",
                    "protocols": [LIVE_RELOAD_PROTOCOL],
                    "serverName": "pandocmd",
                })

    def read_frame(self):
        header = self.read_exact(2)
        if header is None:
            return None

        first, second = header
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F

        if length == 126:
            raw_length = self.read_exact(2)
            if raw_length is None:
                return None
            length = struct.unpack("!H", raw_length)[0]
        elif length == 127:
            raw_length = self.read_exact(8)
            if raw_length is None:
                return None
            length = struct.unpack("!Q", raw_length)[0]

        mask = b""
        if masked:
            mask = self.read_exact(4)
            if mask is None:
                return None

        payload = self.read_exact(length)
        if payload is None:
            return None

        if masked:
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))

        return opcode, payload

    def read_exact(self, size):
        chunks = []
        remaining = size

        while remaining > 0:
            try:
                chunk = self.socket.recv(remaining)
            except OSError:
                return None

            if not chunk:
                return None

            chunks.append(chunk)
            remaining -= len(chunk)

        return b"".join(chunks)

    def send_json(self, payload):
        return self.send_text(json.dumps(payload, separators=(",", ":")))

    def send_text(self, text):
        return self.send_frame(0x1, text.encode("utf-8"))

    def send_frame(self, opcode, payload):
        with self.send_lock:
            if not self.open:
                return False

            frame = bytearray([0x80 | opcode])
            length = len(payload)
            if length < 126:
                frame.append(length)
            elif length < 65536:
                frame.extend(struct.pack("!BH", 126, length))
            else:
                frame.extend(struct.pack("!BQ", 127, length))
            frame.extend(payload)

            try:
                self.socket.sendall(frame)
            except OSError:
                self.open = False
                return False

        return True

    def close(self):
        self.open = False
        try:
            self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.socket.close()
        except OSError:
            pass


class PreviewHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, directory=None, hub=None, **kwargs):
        self.hub = hub
        super().__init__(*args, directory=directory, **kwargs)

    def end_headers(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/preview/") and path.endswith(".html"):
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        elif path.startswith("/fonts/") or path.startswith("/katex/"):
            # Fonts and the KaTeX runtime do not change while editing, so let the
            # browser reuse them across reloads with no revalidation round-trip.
            # This is what keeps the web fonts ready before first paint, so live
            # reload no longer flashes a fallback font and reflows the page.
            self.send_header("Cache-Control", "public, max-age=604800, immutable")
        else:
            # Stylesheets and other assets are edited live; revalidate so edits
            # show on the next reload (a 304 when unchanged is cheap).
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/livereload":
            self.handle_livereload()
            return
        if path == "/__pandocmd/live-reload/health":
            self.handle_reload_health()
            return

        super().do_GET()

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/__pandocmd/live-reload":
            self.handle_reload_signal()
            return

        self.send_error(404)

    def handle_livereload(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        if (
            self.headers.get("Upgrade", "").lower() != "websocket"
            or "upgrade" not in self.headers.get("Connection", "").lower()
            or not key
        ):
            self.send_error(400, "Expected a WebSocket upgrade")
            return

        if not self.origin_allowed():
            self.send_error(403)
            return

        accept = base64.b64encode(
            hashlib.sha1((key + WEBSOCKET_MAGIC).encode("ascii")).digest()
        ).decode("ascii")

        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True

        client = LiveReloadClient(self)
        self.hub.register(client)
        try:
            client.read_loop()
        finally:
            self.hub.unregister(client)
            client.close()

    def origin_allowed(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True

        parsed = urllib.parse.urlparse(origin)
        origin_host = (parsed.hostname or "").lower()
        request_host = (self.headers.get("Host", "").split(":", 1)[0]).lower()

        return origin_host == request_host

    def handle_reload_signal(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(min(length, 4096))
        path = "/preview/reload.html"

        if body:
            try:
                payload = json.loads(body.decode("utf-8"))
                path = str(payload.get("path") or path)
            except (UnicodeDecodeError, json.JSONDecodeError):
                self.send_error(400, "Invalid JSON")
                return

        delivered = self.hub.broadcast_reload(path)
        response = json.dumps({"clients": delivered}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def handle_reload_health(self):
        self.send_response(204)
        self.end_headers()


class PreviewServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request, client_address):
        exception = sys.exception()
        if isinstance(exception, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


def main():
    if len(sys.argv) != 3:
        print("Usage: pandocmd-preview-server.py PORT ASSETS_DIR", file=sys.stderr)
        return 2

    port = int(sys.argv[1])
    directory = sys.argv[2]
    hub = LiveReloadHub()
    handler = functools.partial(PreviewHandler, directory=directory, hub=hub)
    PreviewServer(("127.0.0.1", port), handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
