#!/usr/bin/env python3
"""Loopback-only synthetic website storage fixture; never handles real accounts."""
import http.server
import json
import secrets
import threading


class StorageServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        self.token = secrets.token_hex(16)
        self.reports = []
        self.lock = threading.Lock()
        super().__init__(('127.0.0.1', 0), Handler)
        self.origin = f'http://127.0.0.1:{self.server_port}'


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, body, cookie=None):
        raw = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; connect-src 'self'")
        if cookie:
            self.send_header('Set-Cookie', cookie)
        self.end_headers()
        self.wfile.write(raw)

    def valid_host(self):
        return self.headers.get('Host') == self.server.origin.removeprefix('http://')

    def do_GET(self):
        if not self.valid_host():
            self.reply(403, '')
            return
        if self.path not in ('/set', '/check', '/clear'):
            self.reply(404, '')
            return
        action = self.path[1:]
        token = self.server.token
        cookie = (f'fixture={token}; Path=/; Max-Age=86400; HttpOnly; SameSite=Strict'
                  if action == 'set' else 'fixture=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict'
                  if action == 'clear' else None)
        page = """<!doctype html><meta charset=utf-8><title>Synthetic site storage</title>
<h1>Synthetic site storage</h1><p id=status>Checking storage</p><script>
const action=ACTION, expected=TOKEN;
function request(r){return new Promise((resolve,reject)=>{r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(Error('request'));r.onblocked=()=>reject(Error('blocked'))})}
async function database(){const r=indexedDB.open('levistica-fixture',1);r.onupgradeneeded=()=>r.result.createObjectStore('values');return request(r)}
(async()=>{
 if(action==='clear'){localStorage.removeItem('fixture');await request(indexedDB.deleteDatabase('levistica-fixture'))}
 if(action==='set')localStorage.setItem('fixture',expected);
 const db=await database();
 const tx=db.transaction('values',action==='set'?'readwrite':'readonly');
 const done=new Promise((resolve,reject)=>{tx.oncomplete=resolve;tx.onerror=tx.onabort=()=>reject(Error('transaction'))});
 const store=tx.objectStore('values');
 if(action==='set')store.put(expected,'fixture');
 const indexed=await request(store.get('fixture'));await done;db.close();
 const report={action,local:localStorage.getItem('fixture')===expected,indexed:indexed===expected,cookieVisible:document.cookie.split(';').some(c=>c.trim().startsWith('fixture='))};
 const result=await fetch('/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(report)});
 if(!result.ok)throw Error('report');document.querySelector('#status').textContent='Recorded';
})().catch(()=>document.querySelector('#status').textContent='Storage check failed');
</script>""".replace('ACTION', json.dumps(action)).replace('TOKEN', json.dumps(token))
        self.reply(200, page, cookie)

    def do_POST(self):
        if (not self.valid_host() or self.path != '/report'
                or self.headers.get('Origin') != self.server.origin
                or self.headers.get('Content-Type') != 'application/json'):
            self.reply(403, '')
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 512:
                raise ValueError('size')
            report = json.loads(self.rfile.read(length))
            if (not isinstance(report, dict) or set(report) != {'action', 'local', 'indexed', 'cookieVisible'}
                    or report['action'] not in ('set', 'check', 'clear')
                    or any(type(report[k]) is not bool for k in ('local', 'indexed', 'cookieVisible'))):
                raise ValueError('shape')
        except (ValueError, TypeError):
            self.reply(400, '')
            return
        report['serverCookie'] = ('fixture=' + self.server.token) in [s.strip() for s in self.headers.get('Cookie', '').split(';')]
        with self.server.lock:
            if len(self.server.reports) >= 12:
                self.reply(429, '')
                return
            self.server.reports.append(report)
        self.reply(200, 'Recorded')
