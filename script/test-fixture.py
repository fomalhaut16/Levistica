#!/usr/bin/env python3
"""Loopback-only deterministic pages for browser tests; never logs requests."""
import base64
import hashlib
import io
import wave
import http.server
import json
import re
from urllib.parse import parse_qs, urlsplit
import pathlib
import ssl
import socket
import socketserver
import sys
import threading
import time


def synthetic_pdf(port):
    first = b"BT /F1 24 Tf 72 720 Td (Levistica synthetic PDF) Tj 0 -40 Td /F1 16 Tf (Searchable nebula marker) Tj 0 -40 Td (Open second web page) Tj ET"
    second = b"BT /F1 24 Tf 72 720 Td (Second PDF page) Tj ET"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Count 2 /Kids [4 0 R 6 0 R] >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R /Annots [8 0 R] >>",
        b"<< /Length %d >>\nstream\n" % len(first) + first + b"\nendstream",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents 7 0 R >>",
        b"<< /Length %d >>\nstream\n" % len(second) + second + b"\nendstream",
        ("<< /Type /Annot /Subtype /Link /Rect [72 630 350 660] /Border [0 0 1] /A << /S /URI /URI (http://127.0.0.1:%d/two) >> >>" % port).encode()]
    result = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, body in enumerate(objects, 1):
        offsets.append(len(result))
        result.extend(("%d 0 obj\n" % number).encode() + body + b"\nendobj\n")
    xref = len(result)
    result.extend(("xref\n0 %d\n0000000000 65535 f \n" % len(offsets)).encode())
    for offset in offsets[1:]: result.extend(("%010d 00000 n \n" % offset).encode())
    result.extend(("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(offsets), xref)).encode())
    return bytes(result)


def silent_audio_data():
    output = io.BytesIO()
    with wave.open(output, 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(bytes(16000))
    return 'data:audio/wav;base64,' + base64.b64encode(output.getvalue()).decode()


def selection_matches_fixture(payload):
    """Accept only the generated pair, never echo names, contents, or paths."""
    try:
        data = json.loads(payload)
        if not isinstance(data, dict) or set(data) != {'kind', 'files'}:
            return False
        kind = data['kind']
        if kind not in ('files', 'folder') or not isinstance(data['files'], list):
            return False
        prefix = 'SelectedFolder/' if kind == 'folder' else ''
        expected = [
            {'name': 'a.txt', 'path': prefix + 'a.txt' if prefix else '', 'text': 'synthetic A\n'},
            {'name': 'b.txt', 'path': prefix + 'nested/b.txt' if prefix else '', 'text': 'synthetic B\n'}]
        files = data['files']
        if len(files) != 2 or any(not isinstance(item, dict) or set(item) != {'name', 'path', 'text'}
                                  or any(not isinstance(v, str) for v in item.values()) for item in files):
            return False
        return sorted(files, key=lambda item: (item['path'], item['name'])) == expected
    except (ValueError, TypeError, RecursionError):
        return False


def ime_metadata(payload):
    """Accept event categories and bounded counts only, never typed text."""
    try:
        value = json.loads(payload)
        basic = {'ime-input', 'ime-textarea', 'ime-editor'}
        rich = {'ime-plain-editor', 'ime-legacy-model', 'ime-engine-model'}
        controls = basic | rich
        types = {'compositionstart', 'compositionupdate', 'compositionend', 'beforeinput', 'input', 'keydown', 'keyup'}
        if not isinstance(value, dict) or set(value) not in ({'events', 'fields'}, {'events', 'fields', 'classification'}):
            return None
        if not isinstance(value['events'], list) or len(value['events']) > 240:
            return None
        for row in value['events']:
            if not isinstance(row, dict) or row.get('control') not in controls or row.get('type') not in types:
                return None
            keys = {'control', 'type', 'trusted'}
            if type(row.get('trusted')) is not bool:
                return None
            if row['type'] in ('keydown', 'keyup'):
                keys |= {'enter', 'isComposing', 'processKey'}
                if any(type(row.get(k)) is not bool for k in ('enter', 'isComposing', 'processKey')):
                    return None
            elif row['type'] in ('input', 'beforeinput'):
                keys |= {'isComposing', 'inputType'}
                if type(row.get('isComposing')) is not bool or row.get('inputType') not in (
                        'insertCompositionText', 'insertText', 'deleteCompositionText', 'insertFromComposition', 'other'):
                    return None
            if set(row) != keys:
                return None
        fields = value['fields']
        if not isinstance(fields, list) or len(fields) != 3:
            return None
        seen = set()
        for row in fields:
            if not isinstance(row, dict) or set(row) != {'control', 'sends', 'lastLength', 'currentLength'}:
                return None
            name = row['control']
            if name not in controls or name in seen:
                return None
            seen.add(name)
            if any(type(row[k]) is not int or not 0 <= row[k] <= 1000000 for k in ('sends', 'lastLength', 'currentLength')):
                return None
        if seen not in (basic, rich) or any(row['control'] not in seen for row in value['events']):
            return None
        if seen == rich:
            flags = value.get('classification')
            if not isinstance(flags, dict) or set(flags) != {'legacySafari', 'webkit'}:
                return None
            if any(type(flag) is not bool for flag in flags.values()):
                return None
        elif 'classification' in value:
            return None
        return value
    except (ValueError, TypeError, RecursionError):
        return None


class Handler(http.server.BaseHTTPRequestHandler):
    popup_posts = 0
    redirect_303_posts = 0
    redirect_307_posts = 0
    counter_lock = threading.Lock()

    def fixture_redirect(self, status, target):
        self.send_response(status)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def csp_form_response(self):
        route = urlsplit(self.path)
        if route.path not in ('/csp-form-source', '/csp-form-arrival', '/csp-form-count'):
            return False
        params = parse_qs(route.query)
        token = params.get('token', [''])[0]
        if not re.fullmatch(r'[a-f0-9]{32}', token):
            self.send_error(400)
            return True
        if self.command == 'POST':
            expected = ('token=' + token).encode()
            if (route.path != '/csp-form-arrival' or self.headers.get('Content-Length') != str(len(expected))
                    or self.rfile.read(len(expected)) != expected):
                self.close_connection = True
                self.send_error(400)
                return True
        origin = f'http://127.0.0.1:{self.server.server_port}'
        policy_header = None
        content_type = 'text/html; charset=utf-8'
        if route.path == '/csp-form-count':
            with self.server.csp_form_lock:
                count = self.server.csp_form_counts.get(token, 0)
            body = json.dumps({'requests': count}).encode()
            content_type = 'application/json'
        elif route.path == '/csp-form-arrival':
            with self.server.csp_form_lock:
                self.server.csp_form_counts[token] = self.server.csp_form_counts.get(token, 0) + 1
            body = ('<!doctype html><title>Form arrived</title><script>'
                    'parent.postMessage({token:' + json.dumps(token) + ',status:"arrived"},'
                    + json.dumps(origin) + ');</script>').encode()
        else:
            policy = params.get('policy', [''])[0]
            cross = params.get('cross', [''])[0]
            method = params.get('method', ['get'])[0]
            if policy not in ('self', 'none', 'cross') or cross not in ('0', '1') or method not in ('get', 'post'):
                self.send_error(400)
                return True
            target_origin = f'http://localhost:{self.server.server_port}' if cross == '1' else origin
            allowed = f'http://localhost:{self.server.server_port}' if policy == 'cross' else "'" + policy + "'"
            policy_header = "default-src 'none'; script-src 'nonce-levistica-synthetic'; form-action " + allowed
            body = ('<!doctype html><title>CSP form source</title>'
                    '<form id="probe" method="' + method + '" action="' + target_origin + '/csp-form-arrival?token=' + token + '">'
                    '<input type="hidden" name="token" value="' + token + '"></form>'
                    '<script nonce="levistica-synthetic">'
                    'document.addEventListener("securitypolicyviolation",event=>{'
                    'if(event.effectiveDirective==="form-action")parent.postMessage({token:'
                    + json.dumps(token) + ',status:"blocked",directive:event.effectiveDirective,'
                    'disposition:event.disposition},' + json.dumps(origin) + ');});'
                    'document.getElementById("probe").submit();</script>').encode()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        if policy_header:
            self.send_header('Content-Security-Policy', policy_header)
        self.end_headers()
        self.wfile.write(body)
        return True

    def csp_websocket_response(self):
        route = urlsplit(self.path)
        if route.path not in ('/csp-websocket-source', '/csp-websocket-connect', '/csp-websocket-count'):
            return False
        params = parse_qs(route.query)
        token = params.get('token', [''])[0]
        if not re.fullmatch(r'[a-f0-9]{32}', token):
            self.send_error(400)
            return True
        origin = f'http://127.0.0.1:{self.server.server_port}'
        socket_origin = f'ws://127.0.0.1:{self.server.server_port}'
        policy_header = None
        content_type = 'text/html; charset=utf-8'
        if route.path == '/csp-websocket-count':
            with self.server.csp_websocket_lock:
                count = self.server.csp_websocket_counts.get(token, 0)
            body = json.dumps({'requests':count}).encode()
            content_type = 'application/json'
        elif route.path == '/csp-websocket-connect':
            # One fixed server-to-client message, no client payloads or forwarding.
            if self.headers.get('Origin') != origin or self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}':
                self.send_error(403)
                return True
            key = self.headers.get('Sec-WebSocket-Key', '')
            try:
                valid_key = len(base64.b64decode(key, validate=True)) == 16
            except (ValueError, TypeError):
                valid_key = False
            if (not valid_key or self.headers.get('Upgrade', '').lower() != 'websocket'
                    or 'upgrade' not in [value.strip().lower() for value in self.headers.get('Connection', '').split(',')]
                    or self.headers.get('Sec-WebSocket-Version') != '13'):
                self.send_error(400)
                return True
            with self.server.csp_websocket_lock:
                self.server.csp_websocket_counts[token] = self.server.csp_websocket_counts.get(token, 0) + 1
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.protocol_version = 'HTTP/1.1'
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            self.wfile.write(b'\x81\x05ready\x88\x02\x03\xe8')
            self.wfile.flush()
            self.close_connection = True
            return True
        else:
            directive = params.get('directive', [''])[0]
            policy = params.get('policy', [''])[0]
            if directive not in ('default-src', 'connect-src') or policy not in ('allow', 'none'):
                self.send_error(400)
                return True
            source = socket_origin if policy == 'allow' else "'none'"
            policy_header = (("default-src " + source) if directive == 'default-src' else
                             ("default-src 'none'; connect-src " + source)) + "; script-src 'nonce-levistica-websocket'"
            script = ('const token=' + json.dumps(token) + ';let finished=false;'
                      'const report=value=>{if(finished)return;finished=true;parent.postMessage({token,...value},' + json.dumps(origin) + ');};'
                      'document.addEventListener("securitypolicyviolation",event=>{'
                      'if(event.effectiveDirective==="connect-src")report({status:"blocked",directive:event.effectiveDirective,disposition:event.disposition});});'
                      'try{const socket=new WebSocket(' + json.dumps(socket_origin + '/csp-websocket-connect?token=' + token) + ');'
                      'socket.onmessage=event=>{if(event.data==="ready")report({status:"connected"});socket.close();};'
                      'socket.onerror=()=>{setTimeout(()=>report({status:"transport-error"}),100);};}'
                      'catch(error){if(error.name!=="SecurityError")report({status:"constructor-error"});}')
            body = ('<!doctype html><title>CSP WebSocket source</title><script nonce="levistica-websocket">' + script + '</script>').encode()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        if policy_header:
            self.send_header('Content-Security-Policy', policy_header)
        self.end_headers()
        self.wfile.write(body)
        return True

    def csp_worker_response(self):
        route = urlsplit(self.path)
        if route.path not in ('/csp-worker-source', '/csp-worker-script', '/csp-worker-count'):
            return False
        params = parse_qs(route.query)
        token = params.get('token', [''])[0]
        kind = params.get('kind', [''])[0]
        if not re.fullmatch(r'[a-f0-9]{32}', token) or kind not in ('dedicated', 'shared'):
            self.send_error(400)
            return True
        origin = f'http://127.0.0.1:{self.server.server_port}'
        policy_header = None
        content_type = 'text/html; charset=utf-8'
        key = (token, kind)
        if route.path == '/csp-worker-count':
            with self.server.csp_worker_lock:
                count = self.server.csp_worker_counts.get(key, 0)
            body = json.dumps({'requests':count}).encode()
            content_type = 'application/json'
        elif route.path == '/csp-worker-script':
            with self.server.csp_worker_lock:
                self.server.csp_worker_counts[key] = self.server.csp_worker_counts.get(key, 0) + 1
            body = (b'postMessage("ready");close();' if kind == 'dedicated' else
                    b'onconnect=event=>{const port=event.ports[0];port.postMessage("ready");port.close();};')
            content_type = 'application/javascript'
        else:
            policy = params.get('policy', [''])[0]
            if policy not in ('self', 'none'):
                self.send_error(400)
                return True
            policy_header = "default-src 'none'; script-src 'nonce-levistica-worker'; worker-src '" + policy + "'"
            script_url = '/csp-worker-script?token=' + token + '&kind=' + kind
            script = ('const token=' + json.dumps(token) + ',kind=' + json.dumps(kind) + ';'
                      'const report=value=>parent.postMessage({token,...value},' + json.dumps(origin) + ');'
                      'document.addEventListener("securitypolicyviolation",event=>{'
                      'if(event.effectiveDirective==="worker-src")report({status:"blocked",directive:event.effectiveDirective,disposition:event.disposition});});'
                      'try{const Constructor=kind==="shared"?globalThis.SharedWorker:globalThis.Worker;'
                      'if(typeof Constructor!=="function")report({status:"unsupported"});else{'
                      'const worker=new Constructor(' + json.dumps(script_url) + ');'
                      'const endpoint=kind==="shared"?worker.port:worker;'
                      'endpoint.onmessage=event=>{if(event.data==="ready")report({status:"running"});'
                      'if(kind==="shared")endpoint.close();else worker.terminate();};'
                      'worker.onerror=()=>report({status:"worker-error"});'
                      'if(kind==="shared")endpoint.start();}}'
                      'catch(error){if(error.name!=="SecurityError")report({status:"constructor-error"});}')
            body = ('<!doctype html><title>CSP worker source</title><script nonce="levistica-worker">' + script + '</script>').encode()
        self.send_response(200)
        self.send_header('Content-Type',content_type)
        self.send_header('Content-Length',str(len(body)))
        self.send_header('Cache-Control','no-store')
        if policy_header:
            self.send_header('Content-Security-Policy',policy_header)
        self.end_headers()
        self.wfile.write(body)
        return True

    def do_GET(self):
        if self.csp_websocket_response():
            return
        if self.csp_worker_response():
            return
        if self.csp_form_response():
            return
        if self.path.split('?', 1)[0] == '/network-policy-image':
            origin = f'http://127.0.0.1:{self.server.server_port}'
            referer = self.headers.get('Referer', '')
            width = 1 if referer == '' else 2 if referer == origin+'/' else 3 if referer == origin+'/network-policy' else 4
            body = f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="1"><rect width="{width}" height="1"/></svg>'.encode()
            self.send_response(200)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Type', 'image/svg+xml')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path in ['/network-policy-cors-allowed', '/network-policy-cors-denied', '/network-policy-referrer']:
            body = (json.dumps({'referer': self.headers.get('Referer', '')}).encode()
                    if self.path == '/network-policy-referrer' else b'synthetic cross-origin response')
            self.send_response(200)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Type', 'application/json' if self.path == '/network-policy-referrer' else 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('X-Levistica-Fixture-Unexposed', 'synthetic-only')
            if self.path != '/network-policy-cors-denied':
                self.send_header('Access-Control-Allow-Origin', f'http://127.0.0.1:{self.server.server_port}')
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == '/ime-result':
            value = self.server.ime_result
            body = json.dumps({'status': 'waiting'} if value is None else {'status': 'recorded', 'result': value}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == '/address-route-wait':
            body = json.dumps({'changed': self.server.address_route_event.wait(timeout=30)}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/redirect-tls":
            self.fixture_redirect(302, self.server.fixture_tls_url + "/two")
            return
        if self.path in ["/redirect-two", "/redirect-download", "/redirect-failure"]:
            target = {"/redirect-two": "/two", "/redirect-download": "/download",
                      "/redirect-failure": self.server.fixture_failure_url + "/failure"}[self.path]
            self.fixture_redirect(302, target)
            return
        if self.path == "/redirect-post-count":
            with self.counter_lock:
                body = json.dumps({"post303": Handler.redirect_303_posts,
                                   "post307": Handler.redirect_307_posts}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/protected.pdf" and "levistica_pdf=synthetic" not in self.headers.get("Cookie", ""):
            self.send_error(403, "Synthetic PDF cookie required")
            return
        if self.path in ["/fixture.pdf", "/attachment.pdf", "/protected.pdf"]:
            data = synthetic_pdf(self.server.server_address[1])
            self.send_response(200)
            self.send_header("Content-Type", "application/pdf")
            self.send_header("Content-Length", str(len(data)))
            disposition = "attachment" if self.path == "/attachment.pdf" else "inline"
            self.send_header("Content-Disposition", disposition + '; filename="synthetic.pdf"')
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path in ["/download", "/download-slow", "/download-failure"]:
            chunks = 2048 if self.path == "/download-slow" else 1
            chunk = b"levistica synthetic download\n" if chunks == 1 else b"x" * 4096
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="fixture-download.txt"')
            self.send_header("Content-Length", str(len(chunk) * chunks if self.path != "/download-failure" else 1000000))
            self.end_headers()
            try:
                for _ in range(chunks):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    if chunks > 1: time.sleep(0.025)
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
            return
        if self.path in ["/site-data-set", "/site-data-check"]:
            seed = "document.cookie='levistica_site_data=synthetic; SameSite=Lax; Path=/';localStorage.setItem('levistica_site_data','synthetic');" if self.path == "/site-data-set" else ""
            page = """<title>Site data fixture</title><h1>Site data fixture</h1><input aria-label="Storage draft">
                <button onclick="check()">Check saved data</button><p id="cookie-status"></p><p id="storage-status"></p>
                <script>function check(){document.getElementById('cookie-status').textContent=document.cookie.includes('levistica_site_data=')?'Cookie present':'Cookie absent';document.getElementById('storage-status').textContent=localStorage.getItem('levistica_site_data')===null?'Storage absent':'Storage present';}
                """ + seed + "check();</script>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(page.encode())
            return
        pages = {
            '/ime-rich-check': '''<title>Rich editor IME check</title>
                <style>body{font:15px system-ui;max-width:780px;margin:24px auto;padding:0 18px}h1{font-size:24px}.editor{font:22px system-ui;border:1px solid #888;padding:12px;min-height:32px;margin:8px 0}section{margin:24px 0}output{font-weight:600}pre{max-height:160px;overflow:auto;background:#eee;padding:10px;font:11px monospace;white-space:pre-wrap}</style>
                <h1>文字の確定を3つの編集方法で比較</h1>
                <p>各欄へ日本語IMEで「こんにちは」を入力し、Enterを1回だけ押して確定してください。貼り付けや追加のEnterは不要です。最後に「結果を記録」を押してください。</p>
                <p>このページに送信機能はありません。ブラウザの標準編集と、文字を独自に管理する編集を比べます。Discordの実装そのものを再現したページではありません。</p>
                <p id="classification"></p>
                <section><label for="ime-plain-editor">1. ブラウザの標準編集</label><div class="editor" id="ime-plain-editor" contenteditable="true" role="textbox" aria-label="Plain IME editor" spellcheck="false"></div><output id="ime-plain-editor-result">入力文字数0</output></section>
                <section><label for="ime-legacy-model">2. 旧方式のブラウザ判定を使う編集</label><div class="editor" id="ime-legacy-model" contenteditable="true" role="textbox" aria-label="Legacy model IME editor" spellcheck="false"></div><output id="ime-legacy-model-result">入力文字数0</output></section>
                <section><label for="ime-engine-model">3. エンジンを判定する編集</label><div class="editor" id="ime-engine-model" contenteditable="true" role="textbox" aria-label="Engine model IME editor" spellcheck="false"></div><output id="ime-engine-model-result">入力文字数0</output></section>
                <button id="record">結果を記録</button> <span id="record-status"></span>
                <p>記録はイベント分類・文字数・ブラウザ判定の真偽だけです。入力本文は含めず、このMacの確認用サーバーへ保存します。</p><pre id="events">[]</pre>
                <script>(()=>{
                    const classification={legacySafari:/Version\\/[\\d.]+.*Safari/.test(navigator.userAgent),webkit:/AppleWebKit(?!.*Chrome)/i.test(navigator.userAgent)};
                    const firefox=/Firefox/i.test(navigator.userAgent);
                    document.getElementById('classification').textContent='旧方式のSafari判定: '+classification.legacySafari+' / WebKit判定: '+classification.webkit;
                    const controls=[...document.querySelectorAll('.editor')], log=[];
                    for(const editor of controls){
                        const modelled=editor.id!=='ime-plain-editor';
                        const nativeCommit=editor.id==='ime-legacy-model'?classification.legacySafari:classification.webkit;
                        let model='';
                        // Reduced comparison of two commit paths, not a bundled editor library.
                        // Historical reference: Slate 788a8ce, environment.ts and editable.tsx.
                        if(modelled){
                            editor.addEventListener('compositionstart',()=>{model=editor.textContent;});
                            editor.addEventListener('beforeinput',event=>{
                                if(event.inputType==='insertFromComposition'){
                                    event.preventDefault(); model+=event.data||'';
                                }
                            });
                            editor.addEventListener('compositionend',event=>{
                                if(!nativeCommit&&!firefox) model+=event.data||'';
                                editor.textContent=model;
                                const selection=getSelection(),range=document.createRange();
                                range.selectNodeContents(editor);range.collapse(false);
                                selection.removeAllRanges();selection.addRange(range);
                            });
                        }
                        const update=()=>{document.getElementById(editor.id+'-result').textContent='入力文字数'+editor.textContent.length;};
                        for(const type of ['compositionstart','compositionupdate','compositionend','beforeinput','input','keydown','keyup']){
                            editor.addEventListener(type,event=>{
                                const row={control:editor.id,type,trusted:event.isTrusted};
                                if(event instanceof KeyboardEvent){row.enter=event.key==='Enter';row.isComposing=event.isComposing;row.processKey=event.keyCode===229;}
                                if(event instanceof InputEvent){row.isComposing=event.isComposing;row.inputType=['insertCompositionText','insertText','deleteCompositionText','insertFromComposition'].includes(event.inputType)?event.inputType:'other';}
                                log.push(row);if(log.length>240)log.shift();
                                update();document.getElementById('events').textContent=JSON.stringify(log,null,2);
                            });
                        }
                        editor.addEventListener('keydown',event=>{if(event.key==='Enter'&&!event.isComposing)event.preventDefault();});
                    }
                    document.getElementById('record').onclick=()=>{
                        const fields=controls.map(editor=>({control:editor.id,sends:0,lastLength:0,currentLength:editor.textContent.length}));
                        fetch('/ime-result',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({events:log,fields,classification})})
                            .then(response=>document.getElementById('record-status').textContent=response.ok?'記録しました':'記録できませんでした')
                            .catch(()=>document.getElementById('record-status').textContent='記録できませんでした');
                    };
                })();</script>''',
            '/login-flow': '''<title>Login flow fixture</title>
                <form id="login"><input aria-label="Synthetic login input" autocomplete="off">
                <button>Complete synthetic login</button></form>
                <script>document.getElementById('login').addEventListener('submit',async event=>{
                    event.preventDefault();
                    const response=await fetch('/two');
                    if(response.ok) location.assign('/login-flow-done');
                });</script>''',
            '/login-flow-done': '<title>Login flow completed</title><h1>Synthetic login completed</h1>',
            '/ime-check': '''<title>IME input check</title>
                <style>body{font:14px system-ui;margin:16px}h1{font-size:22px}.row{display:grid;grid-template-columns:100px 1fr 150px;gap:12px;align-items:center;margin:12px 0}input,textarea,[contenteditable]{font:18px system-ui;border:1px solid #888;padding:8px;min-height:28px}pre{font:11px monospace;max-height:180px;overflow:auto;background:#eee;padding:8px;white-space:pre-wrap}</style>
                <h1>日本語IMEの確定を確認</h1>
                <p>指定の「こんにちは」だけを各欄に入力し、未確定の文字をEnterで確定してください。まだ送信用のEnterは押さないでください。</p>
                <p>各欄はEnterで送る単純なチャットの再現です。実際のメッセージ送信は行いません。</p>
                <div class="row"><label for="ime-input">input</label><input id="ime-input" data-ime-probe aria-label="IME input" autocomplete="off"><output id="ime-input-result">送信0回・文字数0</output></div>
                <div class="row"><label for="ime-textarea">textarea</label><textarea id="ime-textarea" data-ime-probe aria-label="IME textarea" rows="1"></textarea><output id="ime-textarea-result">送信0回・文字数0</output></div>
                <div class="row"><span>contenteditable</span><div id="ime-editor" data-ime-probe contenteditable="true" role="textbox" aria-label="IME editor" spellcheck="false"></div><output id="ime-editor-result">送信0回・文字数0</output></div>
                <button id="reset">確認をやり直す</button> <button id="record">結果を記録</button><span id="record-status"></span>
                <p>記録するのはイベントの種類・IME状態・回数・文字数です。入力本文やキーの文字は含めず、このMac内の確認用サーバーだけへ送ります。</p>
                <pre id="events" aria-label="IME event metadata">[]</pre>
                <script>(()=>{
                    const log=[], counts=new Map(), lengths=new Map();
                    const controls=[...document.querySelectorAll('[data-ime-probe]')];
                    for(const control of controls){
                        counts.set(control.id,0);lengths.set(control.id,0);
                        for(const type of ['compositionstart','compositionupdate','compositionend','beforeinput','input','keydown','keyup']){
                            control.addEventListener(type,event=>{
                                const row={control:control.id,type,trusted:event.isTrusted};
                                if(event instanceof KeyboardEvent){row.enter=event.key==='Enter';row.isComposing=event.isComposing;row.processKey=event.keyCode===229;}
                                if(event instanceof InputEvent){row.isComposing=event.isComposing;row.inputType=['insertCompositionText','insertText','deleteCompositionText','insertFromComposition'].includes(event.inputType)?event.inputType:'other';}
                                log.push(row);if(log.length>240)log.shift();document.getElementById('events').textContent=JSON.stringify(log,null,1);
                            },true);
                        }
                        control.addEventListener('keydown',event=>{
                            if(event.key!=='Enter'||event.shiftKey||event.isComposing)return;
                            event.preventDefault();
                            const length=(control.isContentEditable?control.textContent:control.value).length;
                            lengths.set(control.id,length);
                            counts.set(control.id,counts.get(control.id)+1);
                            document.getElementById(control.id+'-result').textContent='送信'+counts.get(control.id)+'回・文字数'+length;
                            if(control.isContentEditable)control.textContent='';else control.value='';
                        });
                    }
                    document.getElementById('reset').onclick=()=>{
                        for(const control of controls){counts.set(control.id,0);lengths.set(control.id,0);if(control.isContentEditable)control.textContent='';else control.value='';document.getElementById(control.id+'-result').textContent='送信0回・文字数0';}
                        log.length=0;document.getElementById('events').textContent='[]';
                    };
                    document.getElementById('record').onclick=()=>{
                        const fields=controls.map(c=>({control:c.id,sends:counts.get(c.id),lastLength:lengths.get(c.id),currentLength:(c.isContentEditable?c.textContent:c.value).length}));
                        fetch('/ime-result',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({events:log,fields})})
                            .then(r=>document.getElementById('record-status').textContent=r.ok?'記録しました':'記録できませんでした')
                            .catch(()=>document.getElementById('record-status').textContent='記録できませんでした');
                    };
                })();</script>''',
            '/address-route': '''<title>Address route fixture</title><h1>Address route fixture</h1>
                <p id="status">Route ready</p><script>
                fetch('/address-route-wait',{cache:'no-store'}).then(r=>r.json()).then(state=>{
                    if(state.changed){history.pushState({},'', '/address-route/changed');
                        document.title='Address route changed';document.getElementById('status').textContent='Route changed';}
                    else{document.getElementById('status').textContent='Route wait expired';}
                });</script>''',
            "/spa": '''<title>SPA start</title><h1>SPA fixture</h1>
                <button onclick="history.pushState({},'', '/spa/second');document.title='SPA second';statusLine.textContent='Second route'">Push route</button>
                <button onclick="history.replaceState({},'', '/spa/replaced');document.title='SPA replaced';statusLine.textContent='Replaced route'">Replace route</button>
                <button onclick="history.pushState({},'', '/spa?token=synthetic');document.title='Excluded route';statusLine.textContent='Excluded route'">Sensitive route</button>
                <button onclick="document.title='SPA renamed';statusLine.textContent='Renamed route'">Rename route</button>
                <p id="statusLine">Start route</p>''',
            "/network-policy": '<title>Network policy fixture</title><h1>Network policy fixture</h1>',
            "/search-flow": '<title>Search flow fixture</title><h1>Search fixture</h1><form role="search" action="/search-results"><input aria-label="Search query" name="q"><button>Search fixture query</button></form>',
            "/search-results": '<title>Search results fixture</title><h1>Search fixture results</h1><a href="/two">Result page</a>',
            "/departure": '''<title>Departure fixture</title><h1>Departure fixture</h1>
                <input aria-label="Departure draft"><a href="/two">Leave draft</a>
                <a href="#section">Same document</a><p id="section">Same document section</p>
                <form action="/submitted" method="post"><input aria-label="Submission draft" name="draft"><button>Send draft</button></form>''',
            "/pdf-cookie": '<title>PDF cookie fixture</title><a href="/protected.pdf">Protected PDF</a>',
            "/pdf-post-form": '<title>PDF POST form</title><form action="/pdf-post" method="post"><button>Submit PDF fixture</button></form>',
            "/input-guard": '''<title>Input guard fixture</title><h1>Input guard fixture</h1>
                <input aria-label="Guard draft" id="guard-draft">
                <button onclick="const field=document.getElementById('guard-draft');field.value='synthetic programmatic value';field.dispatchEvent(new Event('input',{bubbles:true,composed:true}));document.getElementById('bridge-status').textContent=typeof window.webkit?.messageHandlers?.levisticaInputActivity==='undefined'?'Page native handler absent':'Page native handler exposed'">Programmatic input</button>
                <p id="bridge-status">Waiting</p><iframe title="Input frame" id="input-frame"></iframe>
                <script>document.getElementById('input-frame').src='http://localhost:'+location.port+'/input-frame';</script>''',
            "/input-frame": '<title>Input frame</title><input aria-label="Frame draft">',
            "/dialogs": '''<title>Dialogs fixture</title><h1>Dialogs fixture</h1>
                <button onclick="alert('Synthetic site notice'); result.textContent='Alert returned'">Site alert</button>
                <button onclick="result.textContent='Confirm: '+confirm('Synthetic confirmation')">Site confirm</button>
                <button onclick="const reply=prompt('Synthetic prompt','fixture default');result.textContent='Prompt: '+(reply===null?'cancelled':reply)">Site prompt</button>
                <button onclick="alert(Array.from({length:600},(_,i)=>'Synthetic long line '+i).join('\\n'));result.textContent='Long alert returned'">Long site alert</button>
                <button onclick="for(let n=0;n<8;n++){alert('Synthetic loop '+n)} result.textContent='Dialogs completed: 8'">Repeated alerts</button>
                <p id="result">Waiting for dialog</p>
                <iframe title="Dialog frame" id="child"></iframe>
                <script>child.src='http://localhost:'+location.port+'/dialog-frame';</script>''',
            "/dialog-frame": '''<title>Dialog frame</title><button onclick="document.getElementById('frame-result').textContent='Frame: '+confirm('Synthetic frame confirmation')">Frame confirm</button><p id="frame-result"></p>''',
            "/files": '''<title>Files fixture</title><h1>Files fixture</h1>
                <a href="/download">Download fixture</a>
                <a href="/download-slow">Slow download</a>
                <a href="/download-failure">Failed download</a>
                <input type="file" aria-label="Attachment" id="attachment" onchange="document.getElementById('selected').textContent=this.files[0]?.name || 'No selection'">
                <p id="selected">No selection</p><p id="upload-result"></p>
                <button onclick="fetch('/upload-fixture',{method:'POST',body:document.getElementById('attachment').files[0]}).then(r=>r.text()).then(t=>document.getElementById('upload-result').textContent=t)">Upload synthetic fixture</button>''',
            "/upload-selection": '''<title>Selection fixture</title><h1>Selection fixture</h1>
                <input type="file" multiple aria-label="Multiple attachments" id="files" onchange="describe('files')">
                <p id="files-summary">No file selection</p>
                <button onclick="send('files')">Upload selected files</button>
                <input type="file" multiple webkitdirectory aria-label="Folder attachment" id="folder" onchange="describe('folder')">
                <p id="folder-summary">No folder selection</p>
                <button onclick="send('folder')">Upload selected folder</button>
                <p id="selection-result"></p>
                <script>
                function describe(kind) {
                  document.getElementById(kind+'-summary').textContent =
                    [...document.getElementById(kind).files].map(f=>f.webkitRelativePath||f.name).sort().join(' | ')
                    || (kind==='files'?'No file selection':'No folder selection');
                }
                async function send(kind) {
                  const files=await Promise.all([...document.getElementById(kind).files].map(async f=>
                    ({name:f.name,path:f.webkitRelativePath,text:await f.text()})));
                  const response=await fetch('/upload-selection',{method:'POST',headers:{'Content-Type':'application/json'},
                    body:JSON.stringify({kind,files})});
                  document.getElementById('selection-result').textContent=await response.text();
                }
                </script>''',
            "/related": '''<title>Related page opener</title><h1>Related page opener</h1>
                <input aria-label="Draft"><p id="result">Waiting for related page</p>
                <a href="/two">Ordinary link</a>
                <a href="/two" target="_blank">New target link</a>
                <a href="levistica-test-native:blocked" target="_blank">Blocked new target</a>
                <button onclick="child=window.open('/popup-child', 'auth-fixture', 'width=640,height=500')">Open related page</button>
                <button onclick="child=window.open('', 'blank-fixture'); if(child) child.location.href='/popup-child'">Open blank related page</button>
                <form action="/popup-post" method="post" target="post-fixture"><input name="draft" value="synthetic"><button>Submit in related page</button></form>
                <script>let child;
                document.cookie='levistica_fixture=synthetic; SameSite=Lax; path=/';
                addEventListener('message', event => {
                  if(event.origin===location.origin && event.source===child && event.data==='synthetic-complete')
                    document.getElementById('result').textContent='Related page completed';
                });</script>''',
            "/popup-child": '''<title>Related child</title><h1>Related child</h1><p id="cookie"></p><input aria-label="Child draft">
                <button onclick="window.opener.postMessage('synthetic-complete', location.origin); window.close()">Send result and close</button>
                <script>document.getElementById('cookie').textContent = document.cookie.includes('levistica_fixture=synthetic') ? 'Shared fixture cookie' : 'Missing fixture cookie';</script>''',
            "/automatic-popup": '''<title>Automatic popup fixture</title><p id="state">Waiting</p>
                <script>setTimeout(() => { const child=window.open('/popup-child','unsolicited-fixture');
                document.getElementById('state').textContent=child ? 'Automatic popup opened' : 'Automatic popup blocked'; }, 100);</script>''',
            "/popup-burst": '''<title>Popup burst fixture</title><h1>Popup burst fixture</h1>
                <button onclick="for(let i=0;i<20;i++) window.open('/burst-child','burst-'+i)">Open twenty related pages</button>''',
            "/burst-child": '<title>Burst child</title><h1>Burst child</h1>',
            "/sleep-media": '''<title>Sleep media fixture</title><h1>Sleep media fixture</h1><p id="state">No media</p>
                <button onclick="play()">Play muted media</button><button onclick="setTimeout(play,10000)">Schedule muted media</button>
                <script>function play(){const media=new Audio(''' + json.dumps(silent_audio_data()) + ''');
                media.muted=true;media.loop=true;media.onplaying=()=>state.textContent='Muted media playing';
                document.body.append(media);media.play();}</script>''',
            "/sleep-state": '''<title>Sleep fixture</title><h1>Sleep fixture</h1><p id="loads"></p><p id="marker">Fresh page</p>
                <button onclick="marker.textContent='Transient marker'">Change page marker</button>
                <script>const n=+(document.cookie.match(/(?:^|; )sleep_loads=([0-9]+)/)?.[1]||0)+1;
                document.cookie='sleep_loads='+n+'; SameSite=Lax; path=/';loads.textContent='Sleep loads: '+n;</script>''',
            "/tab-state": '<title>State tab</title><h1>State tab</h1><input aria-label="Draft"><p id="loads"></p><script>const n=+(sessionStorage.getItem("loads")||0)+1;sessionStorage.setItem("loads",n);document.getElementById("loads").textContent="Document loads: "+n;</script>',
            "/post-form": '<h1>Post fixture</h1><form action="/submitted" method="post"><input name="draft" value="synthetic"><button>Submit fixture</button></form>',
            "/submitted": '<h1>Unexpected GET replay</h1>',
            "/video-actions": '''<title>Player action fixture</title><h1>Player actions</h1>
                <style>body{padding:24px}button{padding:12px;margin:6px}</style>
                <p id="wrong">Wrong actions: 0</p>
                <button onclick="wrong.textContent='Wrong actions: 1'">再生リストに保存</button>
                <button onclick="wrong.textContent='Wrong actions: 1'">ミュート設定を開く</button>
                <button onclick="this.textContent='一時停止 (k)'">再生 (k)</button>
                <button onclick="this.textContent='ミュート解除 キーボード ショートカット m'">ミュート（消音） キーボード ショートカット m</button>''',
            "/web-menu": '''<title>Web menu fixture</title><h1>Nested web menu</h1>
                <style>body{padding:24px}button{padding:12px;margin:6px}[hidden]{display:none}
                [role=menu]{padding:12px;border:1px solid #555;width:240px}</style>
                <button onclick="result.textContent='Wrong settings'">Settings</button>
                <button id="settings" aria-haspopup="menu" aria-expanded="false"
                  onclick="menu.hidden=!menu.hidden;this.setAttribute('aria-expanded',String(!menu.hidden))">Settings</button>
                <div id="menu" role="menu" hidden>
                  <button role="menuitem" aria-haspopup="menu" aria-expanded="false"
                    onclick="levels.hidden=false;this.setAttribute('aria-expanded','true')">Quality Auto (480p)</button>
                </div>
                <div id="levels" role="menu" hidden>
                  <button role="menuitemradio" aria-checked="false"
                    onclick="this.setAttribute('aria-checked','true');result.textContent='Selected 720p60'">720p60</button>
                </div><p id="result" role="status">No selection</p>''',
            "/one": '<title>Fixture one</title><h1>Levistica fixture one</h1><a href="/two">Second page</a><a href="levistica-test-native:blocked">Blocked native link</a>',
            "/two": '<title>Fixture two</title><h1>Levistica fixture two</h1><a href="/one">First page</a><input aria-label="Draft">',
            "/fullscreen": '''<style>
                body { padding: 40px 0; }
                .corner { position: fixed; padding: 5px 8px; color: white; font: bold 12px monospace; pointer-events: none; z-index: 10; }
                .tl { top: 8px; left: 8px; background: #a00030; }
                .tr { top: 8px; right: 8px; background: #0055aa; }
                .bl { bottom: 8px; left: 8px; background: #167040; }
                .br { bottom: 8px; right: 8px; background: #7040a0; }
                </style><span class="corner tl">TOP LEFT</span><span class="corner tr">TOP RIGHT</span>
                <span class="corner bl">BOTTOM LEFT</span><span class="corner br">BOTTOM RIGHT</span>
                <h1>Fullscreen fixture</h1><p id="state">windowed</p>
                <button onclick="document.documentElement.requestFullscreen().catch(e => document.getElementById('state').textContent = 'fullscreen failed: ' + e.name)">Enter fullscreen</button>
                <button onclick="document.exitFullscreen()">Exit fullscreen</button>
                <input aria-label="Fullscreen draft">
                <script>document.addEventListener('fullscreenchange', () => {
                  document.getElementById('state').textContent = document.fullscreenElement ? 'fullscreen active' : 'windowed';
                });</script>''',
        }
        pages["/fullscreen-dark"] = pages["/fullscreen"].replace(
            "<style>", "<style>html, body { background: #181818; color: white; }", 1)
        route = self.path.split("?", 1)[0]
        body = ("<!doctype html><meta charset=utf-8>" + pages.get(route, "Not found")).encode()
        self.send_response(200 if route in pages else 404)
        if self.path == "/pdf-cookie": self.send_header("Set-Cookie", "levistica_pdf=synthetic; HttpOnly; SameSite=Lax; Path=/")
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.csp_form_response():
            return
        if self.path == '/ime-result':
            if self.headers.get('Origin') != f'http://127.0.0.1:{self.server.server_port}':
                self.send_error(403)
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
            except ValueError:
                self.send_error(400)
                return
            if not 0 < length <= 65536:
                self.send_error(413)
                return
            value = ime_metadata(self.rfile.read(length))
            if value is None:
                self.send_error(400)
                return
            self.server.ime_result = value
            self.send_response(204)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path in ('/address-route-reset', '/address-route-trigger'):
            if self.headers.get('Origin') != f'http://127.0.0.1:{self.server.server_port}':
                self.send_error(403)
                return
            if self.headers.get('Content-Length', '0') != '0':
                self.send_error(400)
                return
            if self.path.endswith('reset'):
                self.server.address_route_event.clear()
            else:
                self.server.address_route_event.set()
            self.send_response(204)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/upload-selection':
            expected_origin = f'http://127.0.0.1:{self.server.server_port}'
            if self.headers.get('Origin') != expected_origin:
                self.send_error(403)
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
            except ValueError:
                self.send_error(400)
                return
            if not 0 < length <= 8192:
                self.send_error(413)
                return
            accepted = selection_matches_fixture(self.rfile.read(length))
            body = b'Selected synthetic files received' if accepted else b'Unexpected synthetic selection'
            self.send_response(200 if accepted else 400)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        received = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path in ["/redirect-303", "/redirect-307"]:
            if self.path == "/redirect-303":
                with self.counter_lock:
                    Handler.redirect_303_posts += 1
                self.fixture_redirect(303, "/two")
            else:
                self.fixture_redirect(307, "/redirect-post-target")
            return
        if self.path == "/redirect-post-target":
            if received != b"synthetic=1":
                self.send_error(400, "Synthetic POST body was not preserved")
                return
            with self.counter_lock:
                Handler.redirect_307_posts += 1
            body = b"<!doctype html><title>Redirect POST fixture</title><h1>Redirect POST received</h1>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/pdf-post":
            body = synthetic_pdf(self.server.server_address[1])
            self.send_response(200)
            self.send_header("Content-Type", "application/pdf")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/upload-fixture":
            body = b"Synthetic upload received" if received == b"levistica synthetic upload\n" else b"Unexpected fixture bytes"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        body = b"<!doctype html><title>Submitted</title><h1>Submission received</h1><a href='/download'>Download fixture</a>"
        if self.path == "/popup-post":
            with self.counter_lock:
                Handler.popup_posts += 1
                count = Handler.popup_posts
            body = f"<!doctype html><title>Popup POST</title><h1>Popup POST received</h1><p>POST deliveries: {count}</p>".encode()
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


class FixtureHTTPServer(http.server.ThreadingHTTPServer):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.address_route_event = threading.Event()
        self.ime_result = None
        self.csp_form_lock = threading.Lock()
        self.csp_form_counts = {}
        self.csp_worker_lock = threading.Lock()
        self.csp_worker_counts = {}
        self.csp_websocket_lock = threading.Lock()
        self.csp_websocket_counts = {}


def main():
    server = FixtureHTTPServer(("127.0.0.1", 0), Handler)
    failed = socketserver.ThreadingTCPServer(("127.0.0.1", 0), DisconnectHandler)
    threading.Thread(target=failed.serve_forever, daemon=True).start()
    tls_server = FixtureHTTPServer(("127.0.0.1", 0), Handler)
    for fixture_server in (server, tls_server):
        fixture_server.fixture_failure_url = f"http://127.0.0.1:{failed.server_address[1]}"
        fixture_server.fixture_tls_url = f"https://127.0.0.1:{tls_server.server_port}"
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


if __name__ == "__main__":
    main()
