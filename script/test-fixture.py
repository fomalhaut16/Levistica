#!/usr/bin/env python3
"""Loopback-only deterministic pages for UI tests; never logs requests."""
import http.server
import json
import pathlib
import ssl
import socket
import sys
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        pages = {
            "/one": '<h1>Levistica fixture one</h1><a href="/two">Second page</a><a href="levistica-test-native:blocked">Blocked native link</a>',
            "/two": '<h1>Levistica fixture two</h1><a href="/one">First page</a><input aria-label="Draft">',
        }
        body = ("<!doctype html><meta charset=utf-8>" + pages.get(self.path, "Not found")).encode()
        self.send_response(200 if self.path in pages else 404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
# Bound but never listening: deterministic connection refusal without a port race.
refused = socket.socket()
refused.bind(("127.0.0.1", 0))
tls_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
tls_server.socket = context.wrap_socket(tls_server.socket, server_side=True)
threading.Thread(target=tls_server.serve_forever, daemon=True).start()
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "url": f"http://127.0.0.1:{server.server_port}",
    "tlsUrl": f"https://127.0.0.1:{tls_server.server_port}",
    "failureUrl": f"http://127.0.0.1:{refused.getsockname()[1]}",
}))
server.serve_forever()
