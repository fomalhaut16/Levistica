#!/usr/bin/env python3
"""Five same-origin synthetic documents; readiness requires visiting every tab."""
import argparse
import hashlib
import http.server
import json
import pathlib
import re
import time


def document(number):
    sections = ''.join(f'<section><h2>Reference section {i}</h2><p>' +
                       'A fixed local document for reproducible browser memory measurement. ' * 12 +
                       '</p></section>' for i in range(240))
    return (f'''<!doctype html><meta charset="utf-8"><title>Levistica documents {number}</title>
<style>body{{width:900px;margin:24px;font:16px system-ui;line-height:1.6}}h2{{font-size:20px}}section{{border-bottom:1px solid #ccc}}</style>
<h1>Levistica documents {number}</h1>''' + sections + '''<script>
const instance=crypto.randomUUID(); let seenVisible=false;
const channel=new BroadcastChannel('levistica-five-documents');
function report(){fetch('/report',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({id:Number(location.pathname.split('/').pop()),instance,seenVisible,
width:innerWidth,height:innerHeight,dpr:devicePixelRatio,visibility:document.visibilityState,
sections:document.querySelectorAll('section').length,complete:document.readyState==='complete'})});}
function visible(){if(document.visibilityState==='visible')requestAnimationFrame(()=>requestAnimationFrame(()=>{seenVisible=true;report();}));else report();}
addEventListener('load',visible);document.addEventListener('visibilitychange',visible);
channel.onmessage=report;
setInterval(()=>{report();if(document.visibilityState==='visible')channel.postMessage('report');},2000);
</script>''').encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=pathlib.Path, required=True)
    args = parser.parse_args()
    bodies = {str(i): document(i) for i in range(1, 6)}
    state = {'kind': 'documents', 'expected_tabs': 5,
             'document_hashes': {k: hashlib.sha256(v).hexdigest() for k, v in bodies.items()},
             'documents': {}, 'loads': 0}
    args.state.parent.mkdir(parents=True, exist_ok=True)

    def save():
        temporary = args.state.with_suffix('.tmp')
        temporary.write_text(json.dumps(state, indent=2) + '\n')
        temporary.replace(args.state)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            match = re.fullmatch('/document/([1-5])', self.path)
            if not match:
                self.send_error(404)
                return
            state['loads'] += 1
            save()
            body = bodies[match[1]]
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path == '/reset':
                state['documents'] = {}
                state['loads'] = 0
                state.pop('ready_monotonic', None)
                save()
            elif self.path == '/report':
                try:
                    length = int(self.headers.get('Content-Length', 0))
                    if not 0 < length <= 1024:
                        raise ValueError()
                    data = json.loads(self.rfile.read(length))
                    key = str(data.get('id'))
                    if key not in bodies or not isinstance(data.get('instance'), str):
                        raise ValueError()
                    old = state['documents'].get(key)
                    if old and old['instance'] != data['instance']:
                        state.pop('ready_monotonic', None)
                    state['documents'][key] = {k: data.get(k) for k in (
                        'instance', 'seenVisible', 'width', 'height', 'dpr', 'visibility', 'sections', 'complete')}
                    state['documents'][key]['reported_monotonic'] = time.monotonic()
                    if len(state['documents']) == 5 and all(d['seenVisible'] is True and d['complete'] is True and d['sections'] == 240 for d in state['documents'].values()):
                        state.setdefault('ready_monotonic', time.monotonic())
                    save()
                except (ValueError, TypeError, AttributeError):
                    self.send_error(400)
                    return
            else:
                self.send_error(404)
                return
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    state['url'] = f'http://127.0.0.1:{server.server_port}/document'
    save()
    print(state['url'], flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
