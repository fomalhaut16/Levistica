#!/usr/bin/env python3
"""Loopback-only deterministic pages for UI tests; never logs requests."""
import http.server
import json
import pathlib
import ssl
import socket
import socketserver
import sys
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        pages = {
            "/tab-state": '<title>State tab</title><h1>State tab</h1><input aria-label="Draft"><p id="loads"></p><script>const n=+(sessionStorage.getItem("loads")||0)+1;sessionStorage.setItem("loads",n);document.getElementById("loads").textContent="Document loads: "+n;</script>',
            "/post-form": '<h1>Post fixture</h1><form action="/submitted" method="post"><input name="draft" value="synthetic"><button>Submit fixture</button></form>',
            "/submitted": '<h1>Unexpected GET replay</h1>',
            "/one": '<h1>Levistica fixture one</h1><a href="/two">Second page</a><a href="levistica-test-native:blocked">Blocked native link</a>',
            "/two": '<h1>Levistica fixture two</h1><a href="/one">First page</a><input aria-label="Draft">',
            "/fullscreen": '''<h1>Fullscreen fixture</h1><p id="state">windowed</p>
                <button onclick="document.documentElement.requestFullscreen()">Enter fullscreen</button>
                <button onclick="document.exitFullscreen()">Exit fullscreen</button>
                <script>document.addEventListener('fullscreenchange', () => {
                  document.getElementById('state').textContent = document.fullscreenElement ? 'fullscreen active' : 'windowed';
                });</script>''',
        }
        body = ("<!doctype html><meta charset=utf-8>" + pages.get(self.path, "Not found")).encode()
        self.send_response(200 if self.path in pages else 404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = b"<!doctype html><title>Submitted</title><h1>Submission received</h1>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class DisconnectHandler(socketserver.BaseRequestHandler):
    def handle(self):
        # Accept, then close before an HTTP response: deterministic transport failure.
        self.request.shutdown(socket.SHUT_RDWR)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
failed = socketserver.ThreadingTCPServer(("127.0.0.1", 0), DisconnectHandler)
threading.Thread(target=failed.serve_forever, daemon=True).start()
tls_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
tls_server.socket = context.wrap_socket(tls_server.socket, server_side=True)
threading.Thread(target=tls_server.serve_forever, daemon=True).start()
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "url": f"http://127.0.0.1:{server.server_port}",
    "tlsUrl": f"https://127.0.0.1:{tls_server.server_port}",
    "failureUrl": f"http://127.0.0.1:{failed.server_address[1]}",
}))
server.serve_forever()
