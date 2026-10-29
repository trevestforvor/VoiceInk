"""Loopback-only fixture for the Phonon-compatible PCM/JSON protocol; no model or microphone required."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import struct
import time


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def exact(self, count):
        data = self.rfile.read(count)
        if len(data) != count:
            raise EOFError()
        return data

    def receive(self):
        first, second = self.exact(2)
        count = second & 127
        if count == 126:
            count = struct.unpack("!H", self.exact(2))[0]
        elif count == 127:
            count = struct.unpack("!Q", self.exact(8))[0]
        assert second & 128, "Client frames must be masked"
        mask = self.exact(4)
        data = bytes(value ^ mask[index % 4] for index, value in enumerate(self.exact(count)))
        return first & 15, data

    def send(self, message):
        data = json.dumps(message).encode() if isinstance(message, dict) else message
        header = bytes([0x81, len(data)]) if len(data) < 126 else bytes([0x81, 126]) + struct.pack("!H", len(data))
        self.connection.sendall(header + data)

    def do_GET(self):
        self.connection.settimeout(5)
        self.close_connection = True
        path = self.path.split("/")[1]
        if path == "reject":
            self.send_error(503)
            return
        if path == "slow":
            time.sleep(0.5)
        try:
            assert self.headers.get("Authorization") == "Bearer local"
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            opcode, initial = self.receive()
            assert opcode == 1 and json.loads(initial) == {"sample_rate": 16000, "format": "pcm_s16le"}
            if path == "malformed":
                self.send(b"not-json")
                return
            if path == "missing-text":
                self.send({"type": "partial"})
                return
            if path == "server-error":
                self.send({"type": "error", "message": "fixture failure"})
                return
            if path == "abrupt":
                return
            for message in [
                {"type": "partial", "text": "hello"}, {"type": "final", "text": "hello"},
                {"type": "partial", "text": "hello"}, {"type": "final", "text": "hello"}
            ]:
                self.send(message)
            while True:
                opcode, data = self.receive()
                if opcode == 8:
                    return
                if opcode == 2:
                    assert len(data) == 640, "Test PCM must be sent as binary without an encoding wrapper"
                if opcode == 1 and json.loads(data).get("type") == "end":
                    self.send({"type": "final", "text": "world"})
                    self.send({"type": "done", "text": "hello hello world"})
                    return
        except (OSError, EOFError):
            pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
