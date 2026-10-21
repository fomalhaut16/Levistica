#!/usr/bin/env python3
"""Loopback-only synthetic video workload; never accepts a page URL or private media."""
import argparse
import hashlib
import http.server
import json
import pathlib
import re
import time

PAGE = b'''<!doctype html><meta charset="utf-8"><title>Levistica video fixture v1</title>
<style>body{margin:0;background:#222;color:white;font:16px system-ui}video{width:640px;height:360px}</style>
<h1>Fixed 720p H.264 video</h1><video autoplay muted loop controls playsinline src="/video.mp4"></video>
<script>
const v=document.querySelector('video');
setInterval(()=>{const q=v.getVideoPlaybackQuality?.();fetch('/playback',{
method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({
width:innerWidth,height:innerHeight,dpr:devicePixelRatio,visibility:document.visibilityState,
videoWidth:v.videoWidth,videoHeight:v.videoHeight,currentTime:v.currentTime,
paused:v.paused,ended:v.ended,readyState:v.readyState,muted:v.muted,playbackRate:v.playbackRate,
frames:q?.totalVideoFrames??null,dropped:q?.droppedVideoFrames??null})});},500);
</script>'''


def byte_range(header, size):
    if header is None:
        return 0, size - 1
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", header)
    if not match or not any(match.groups()):
        raise ValueError("Unsupported byte range")
    start, end = match.groups()
    if not start:
        if int(end) == 0:
            raise ValueError("Empty suffix")
        return max(0, size - int(end)), size - 1
    start, end = int(start), min(int(end), size - 1) if end else size - 1
    if start > end:
        raise ValueError("Unsatisfiable byte range")
    return start, end


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    video = root / '.local/artifacts/video/synthetic-720p.mp4'
    # A fixed generated filename prevents accidentally serving a user's media.
    size = video.stat().st_size
    state = {'kind': 'video', 'media_sha256': hashlib.sha256(video.read_bytes()).hexdigest(),
             'document_sha256': hashlib.sha256(PAGE).hexdigest(), 'media_bytes': size, 'loads': 0}
    args.state.parent.mkdir(parents=True, exist_ok=True)

    def save():
        temporary = args.state.with_suffix('.tmp')
        temporary.write_text(json.dumps(state, indent=2) + '\n')
        temporary.replace(args.state)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/video':
                state['loads'] += 1
                for key in ['ready_monotonic', 'playback', 'last_report_monotonic', 'last_progress_monotonic']:
                    state.pop(key, None)
                save()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(PAGE)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(PAGE)
            elif self.path == '/video.mp4':
                try:
                    start, end = byte_range(self.headers.get('Range'), size)
                except ValueError:
                    self.send_response(416)
                    self.send_header('Content-Range', f'bytes */{size}')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                self.send_response(206 if self.headers.get('Range') else 200)
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(end - start + 1))
                if self.headers.get('Range'):
                    self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
                self.end_headers()
                try:
                    with video.open('rb') as stream:
                        stream.seek(start)
                        remaining = end - start + 1
                        while remaining:
                            chunk = stream.read(min(65536, remaining))
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            remaining -= len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path != '/playback' or not 0 < int(self.headers.get('Content-Length', 0)) <= 1024:
                self.send_error(400)
                return
            try:
                data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                keys = ['width', 'height', 'dpr', 'visibility', 'videoWidth', 'videoHeight',
                        'currentTime', 'paused', 'ended', 'readyState', 'muted', 'playbackRate', 'frames', 'dropped']
                report = {k: data.get(k) for k in keys}
                now = time.monotonic()
                previous = state.get('playback', {})
                if isinstance(report['currentTime'], (int, float)) and report['currentTime'] != previous.get('currentTime'):
                    state['last_progress_monotonic'] = now
                state['playback'] = report
                state['last_report_monotonic'] = now
                if report['paused'] is False and report['videoWidth'] == 1280 and report['videoHeight'] == 720:
                    state.setdefault('ready_monotonic', now)
                save()
            except (ValueError, TypeError, AttributeError):
                self.send_error(400)
                return
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    state['url'] = f'http://127.0.0.1:{server.server_port}/video'
    save()
    print(state['url'], flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
