#!/usr/bin/env python3
"""Five or twenty loopback-only hosts with fixed documents and same-origin SSE pulses.

No DNS changes, browser flags, external assets, or cross-origin page messaging.
This deliberately measures responsive documents with one persistent stream per document,
not idle static pages or real Internet services.
"""
import argparse
import hashlib
import http.server
import importlib.util
import json
import math
import pathlib
import re
import threading
import time
import uuid

COUNTS = (5, 20)


def hosts(count):
    if type(count) is not int or count not in COUNTS:
        raise ValueError('Document count must be 5 or 20')
    return {str(i): f'document-{i}.localhost' for i in range(1, count + 1)}


def document(number, lifecycle=False):
    # Reuse the fixed content, not the old same-origin reporting script.
    path = pathlib.Path(__file__).with_name('document-set-fixture.py')
    spec = importlib.util.spec_from_file_location('fixed_documents', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    content = module.document(number).decode().split('<script>', 1)[0]
    script = '''<script>
const id=__DOCUMENT_ID__, instance=crypto.randomUUID(); let seenVisible=false, pulse=0, sending=false, pending=false;
async function report(){pending=true;if(sending)return;sending=true;
try{while(pending){pending=false;await fetch('/report/'+id,{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({instance,pulse,seenVisible,width:innerWidth,height:innerHeight,
dpr:devicePixelRatio,visibility:document.visibilityState,
sections:document.querySelectorAll('section').length,complete:document.readyState==='complete'})});}}
catch{}finally{sending=false;}}
function visible(){if(document.visibilityState==='visible')requestAnimationFrame(()=>requestAnimationFrame(()=>{seenVisible=true;report();}));else report();}
addEventListener('load',visible);document.addEventListener('visibilitychange',visible);
const events=new EventSource('/events/'+id);
const status=document.createElement('p');document.querySelector('h1').after(status);
events.onmessage=event=>{pulse=Number(event.data);status.textContent='Pulse '+pulse+' on '+location.hostname;report();};
</script>'''.replace('__DOCUMENT_ID__', json.dumps(str(number)))
    if lifecycle:
        script = script.replace('let seenVisible=false,', 'let firstVisibleReadyMS=null; let seenVisible=false,')
        script = script.replace('body:JSON.stringify({instance,pulse,seenVisible,',
                                'body:JSON.stringify({instance,pulse,seenVisible,firstVisibleReadyMS,')
        script = script.replace('seenVisible=true;report();',
                                'if(firstVisibleReadyMS===null)firstVisibleReadyMS=performance.now();seenVisible=true;report();')
    return (content + script).encode()


def validated_report(data, lifecycle=False):
    if not isinstance(data, dict):
        raise ValueError('Invalid report')
    uuid.UUID(data['instance'])
    if len(data['instance']) != 36:
        raise ValueError('Invalid instance')
    if type(data['pulse']) is not int or data['pulse'] < 0:
        raise ValueError('Invalid pulse')
    for key in ('width', 'height', 'dpr'):
        if type(data[key]) not in (int, float) or not math.isfinite(data[key]) or not 0 < data[key] <= 32768:
            raise ValueError('Invalid viewport')
    if (type(data['seenVisible']) is not bool or type(data['complete']) is not bool
            or type(data['sections']) is not int or data['sections'] != 240
            or data['visibility'] not in ('visible', 'hidden')):
        raise ValueError('Invalid document state')
    fields = ('instance', 'pulse', 'seenVisible', 'width', 'height',
              'dpr', 'visibility', 'sections', 'complete')
    if lifecycle:
        value = data.get('firstVisibleReadyMS')
        if ((value is not None and (type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 600000))
                or (data['seenVisible'] and value is None)):
            raise ValueError('Invalid visible readiness time')
        fields += ('firstVisibleReadyMS',)
    return {key: data[key] for key in fields}


def create_server(state_path, count=5, lifecycle=False):
    if lifecycle and count != 5:
        raise ValueError('Lifecycle measurement is limited to five documents')
    assigned_hosts = hosts(count)
    state_path = pathlib.Path(state_path)
    bodies = {key: document(key, lifecycle=lifecycle) for key in assigned_hosts}
    lock = threading.Lock()
    state = {'kind': 'cross-site-documents', 'transport': 'same-origin-sse-v1',
             'run_id': str(uuid.uuid4()), 'expected_tabs': count, 'loads': 0,
             'document_hashes': {key: hashlib.sha256(body).hexdigest() for key, body in bodies.items()},
             'documents': {}, 'stream_connections': {key: 0 for key in assigned_hosts}}
    if lifecycle:
        state.update(kind='sleep-documents', transport='same-origin-sse-lifecycle-v1',
                     document_loads={key: 0 for key in assigned_hosts},
                     active_streams={key: 0 for key in assigned_hosts})

    def save():
        temporary = state_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(state, indent=2) + '\n')
        temporary.replace(state_path)

    class Handler(http.server.BaseHTTPRequestHandler):
        def route(self, prefix):
            match = re.fullmatch(prefix + '/([1-9][0-9]*)', self.path)
            if not match or match[1] not in assigned_hosts:
                return None
            key = match[1]
            expected = f'{assigned_hosts[key]}:{self.server.server_port}'
            return key if self.headers.get('Host') == expected else None

        def do_GET(self):
            key = self.route('/document')
            if key:
                with lock:
                    state['loads'] += 1
                    if lifecycle:
                        state['document_loads'][key] += 1
                    save()
                body = bodies[key]
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body)
                return
            key = self.route('/events')
            if not key:
                self.send_error(404)
                return
            with lock:
                state['stream_connections'][key] += 1
                duplicate = state['stream_connections'][key] > 1 and not lifecycle
                if lifecycle:
                    state['active_streams'][key] += 1
                save()
            if duplicate:
                self.send_error(409)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            self.end_headers()
            pulse = 0
            try:
                while not self.server.stopping.is_set():
                    pulse += 1
                    self.wfile.write(f'data: {pulse}\n\n'.encode())
                    self.wfile.flush()
                    if self.server.stopping.wait(2):
                        break
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                if lifecycle:
                    with lock:
                        state['active_streams'][key] -= 1
                        save()

        def do_POST(self):
            key = self.route('/report')
            if not key or self.headers.get('Origin') != state['origins'][key]:
                self.send_error(403)
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if self.headers.get('Content-Type') != 'application/json' or not 0 < length <= 2048:
                    raise ValueError('Invalid content')
                data = validated_report(json.loads(self.rfile.read(length)), lifecycle=lifecycle)
            except (ValueError, TypeError, KeyError, AttributeError):
                self.send_error(400)
                return
            with lock:
                old = state['documents'].get(key)
                if old and old['instance'] != data['instance'] and not lifecycle:
                    state['invalid_reason'] = 'Document instance changed'
                if old and old['instance'] == data['instance'] and old['pulse'] > data['pulse']:
                    state['invalid_reason'] = 'Document pulse moved backwards'
                data['origin'] = state['origins'][key]
                data['reported_monotonic'] = time.monotonic()
                state['documents'][key] = data
                if len(state['documents']) == count and all(
                        d['seenVisible'] and d['complete'] and d['pulse'] > 0
                        for d in state['documents'].values()):
                    state.setdefault('ready_monotonic', time.monotonic())
                save()
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.stopping = threading.Event()
    state['origins'] = {key: f'http://{host}:{server.server_port}' for key, host in assigned_hosts.items()}
    state['urls'] = {key: origin + '/document/' + key for key, origin in state['origins'].items()}
    state_path.parent.mkdir(parents=True, exist_ok=True)
    save()
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=pathlib.Path, required=True)
    parser.add_argument('--count', type=int, choices=COUNTS, default=5)
    parser.add_argument('--lifecycle', action='store_true', help='Five-document manual sleep measurement only')
    args = parser.parse_args()
    server = create_server(args.state, args.count, lifecycle=args.lifecycle)
    print(args.state, flush=True)
    try:
        server.serve_forever()
    finally:
        server.stopping.set()
        server.server_close()


if __name__ == '__main__':
    main()
