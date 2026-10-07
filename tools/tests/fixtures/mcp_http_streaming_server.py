"""Controlled local HTTP fixture for apps/cli/tests/mcp_http_streaming.rs."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError):
            # Cancellation is expected when the client has its result or hits its deadline.
            pass

    def respond(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method, ident = payload["method"], payload.get("id")
        if method != "initialize":
            if self.headers.get("mcp-session-id") != "probe-session":
                self.send_error(400, "session id missing")
                return
            if self.headers.get("mcp-protocol-version") != "2025-03-26":
                self.send_error(400, "negotiated protocol version missing")
                return
        if ident is None:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/headers-timeout":
            time.sleep(1.5)
        if self.path == "/http401":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            body = b'{"error":"authentication required"}'
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if method == "initialize":
            result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "controlled-stream-fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}]}
        else:
            result = {"content": [{"type": "text", "text": "http stream probe ok 中文"}]}
        response = {"jsonrpc": "2.0", "id": ident, "result": result}
        body = json.dumps(response, ensure_ascii=False).encode()
        sse = self.path in ("/sse-short", "/sse-held-open", "/body-timeout", "/sse-eof")
        if sse:
            body = b': heartbeat\r\n\r\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\r\n\r\nevent: message\r\ndata: ' + body + b'\r\n\r\n'
        if self.path == "/body-timeout":
            body = b': heartbeat\n\ndata: {"jsonrpc":"2.0","id":1'
        elif self.path == "/sse-eof":
            body = b': heartbeat\n\n'
        elif self.path == "/bad-json":
            body = b'not-json'
        elif self.path == "/wrong-id":
            body = b'{"jsonrpc":"2.0","id":999,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if sse else "application/json")
        self.send_header("mcp-session-id", "probe-session")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        # Split payloads inside UTF-8 characters and CRLF delimiters.
        for offset in range(0, len(body), 7):
            chunk = body[offset:offset + 7]
            self.wfile.write(f"{len(chunk):X}\r\n".encode() + chunk + b"\r\n")
            self.wfile.flush()
        if self.path in ("/sse-held-open", "/json-held-open", "/body-timeout"):
            time.sleep(1.5)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()



if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    print(server.server_port, flush=True)
    server.serve_forever()
