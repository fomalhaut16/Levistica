#!/usr/bin/env python3
"""Loopback-only deterministic pages for browser tests; never logs requests."""
import base64
import io
import wave
import http.server
import json
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

    def do_GET(self):
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
            "/spa": '''<title>SPA start</title><h1>SPA fixture</h1>
                <button onclick="history.pushState({},'', '/spa/second');document.title='SPA second';statusLine.textContent='Second route'">Push route</button>
                <button onclick="history.replaceState({},'', '/spa/replaced');document.title='SPA replaced';statusLine.textContent='Replaced route'">Replace route</button>
                <button onclick="history.pushState({},'', '/spa?token=synthetic');document.title='Excluded route';statusLine.textContent='Excluded route'">Sensitive route</button>
                <button onclick="document.title='SPA renamed';statusLine.textContent='Renamed route'">Rename route</button>
                <p id="statusLine">Start route</p>''',
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
        body = ("<!doctype html><meta charset=utf-8>" + pages.get(self.path, "Not found")).encode()
        self.send_response(200 if self.path in pages else 404)
        if self.path == "/pdf-cookie": self.send_header("Set-Cookie", "levistica_pdf=synthetic; HttpOnly; SameSite=Lax; Path=/")
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
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


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
failed = socketserver.ThreadingTCPServer(("127.0.0.1", 0), DisconnectHandler)
threading.Thread(target=failed.serve_forever, daemon=True).start()
tls_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
for fixture_server in (server, tls_server):
    fixture_server.fixture_failure_url = f"http://127.0.0.1:{failed.server_address[1]}"
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
