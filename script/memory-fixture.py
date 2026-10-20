#!/usr/bin/env python3
"""Serve one fixed, no-store document on loopback; save only synthetic readiness data."""
import hashlib
import http.server
import json
import pathlib
import sys
import time

output = pathlib.Path(sys.argv[1]).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
sections = ''.join(f'<section><h2>Reference section {i}</h2><p>' +
                   'A fixed local document for reproducible browser memory measurement. ' * 12 +
                   '</p></section>' for i in range(240))
body = ('''<!doctype html><meta charset="utf-8"><title>Levistica memory fixture v1</title>
<style>body{width:900px;margin:24px;font:16px system-ui;line-height:1.6}h2{font-size:20px}section{border-bottom:1px solid #ccc}</style>
<h1>Levistica memory fixture v1</h1>''' + sections + '''<script>
addEventListener('load',()=>requestAnimationFrame(()=>requestAnimationFrame(()=>{
 fetch('/ready',{method:'POST',headers:{'Content-Type':'application/json'},
 body:JSON.stringify({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,
 visibility:document.visibilityState,sections:document.querySelectorAll('section').length})});
})));
</script>''').encode()
state = {'document_sha256': hashlib.sha256(body).hexdigest(), 'document_bytes': len(body), 'loads': 0}


def save():
    output.write_text(json.dumps(state, indent=2) + '\n')


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/document':
            self.send_error(404)
            return
        state['loads'] += 1
        state.pop('ready_monotonic', None)
        save()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != '/ready' or not 0 < int(self.headers.get('Content-Length', 0)) <= 512:
            self.send_error(400)
            return
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        state['viewport'] = {key: data.get(key) for key in ('width', 'height', 'dpr', 'visibility', 'sections')}
        state['ready_monotonic'] = time.monotonic()
        save()
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
state['url'] = f'http://127.0.0.1:{server.server_port}/document'
save()
print(state['url'], flush=True)
server.serve_forever()
