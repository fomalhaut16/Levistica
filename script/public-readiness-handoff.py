#!/usr/bin/env python3
"""Two authenticated live observations; deliberately never collects RAM."""
import argparse
import http.server
import importlib.util
import json
import math
from pathlib import Path
import plistlib
import secrets
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('handoff_deadline', ROOT / 'script/isolated-app-deadline.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def validate_snapshot(value, original=None):
    fields = {'phase', 'pid', 'instance', 'revision', 'documentElapsed', 'mediaTime',
              'width', 'height', 'videoWidth', 'videoHeight', 'dpr', 'muted', 'paused',
              'playbackRate', 'loadedPages', 'readyState'}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError('Unexpected snapshot fields')
    expected_phase = 'before' if original is None else 'after'
    if value['phase'] != expected_phase:
        raise ValueError('Unexpected observation phase')
    numbers = fields - {'phase', 'instance', 'muted', 'paused'}
    if any(type(value[k]) not in (int, float) or not math.isfinite(value[k]) for k in numbers):
        raise ValueError('Snapshot numbers must be finite')
    if (type(value['pid']) is not int or value['pid'] <= 0
            or type(value['revision']) is not int or value['revision'] <= 0
            or not isinstance(value['instance'], str)):
        raise ValueError('Invalid native document identity')
    try:
        uuid.UUID(value['instance'])
    except ValueError:
        raise ValueError('Invalid native document identity') from None
    if ((value['width'], value['height'], value['dpr']) != (779, 683, 2)
            or (value['videoWidth'], value['videoHeight']) != (1280, 720)
            or value['loadedPages'] != 4 or value['playbackRate'] != 1
            or type(value['readyState']) is not int or not 2 <= value['readyState'] <= 4
            or value['muted'] is not True or value['paused'] is not False
            or value['documentElapsed'] <= 0 or value['mediaTime'] < 0):
        raise ValueError('Fixed public playback conditions changed')
    if original is not None:
        if any(value[k] != original[k] for k in ('pid', 'instance', 'revision')):
            raise ValueError('Native document identity changed')
        elapsed = (value['documentElapsed'] - original['documentElapsed']) / 1000
        advanced = value['mediaTime'] - original['mediaTime']
        if not 3 <= elapsed <= 20 or abs(advanced - elapsed) > 2:
            raise ValueError('Live playback interval did not match')


def create_server(pid, verify, clock=time.monotonic):
    token = secrets.token_urlsafe(32)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            supplied = self.headers.get('X-Levistica-Diagnostic', '')
            length = self.headers.get('Content-Length', '')
            if (any(len(self.headers.get_all(name, [])) != 1 for name in
                    ('Host', 'Content-Length', 'Content-Type', 'X-Levistica-Diagnostic'))
                    or self.path != '/public-readiness' or self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}'
                    or self.headers.get('Origin') is not None or self.headers.get('Transfer-Encoding') is not None
                    or not supplied.isascii() or not secrets.compare_digest(supplied, token)
                    or self.headers.get('Content-Type') != 'application/json'
                    or not length.isascii() or not length.isdecimal() or len(length) > 4
                    or not 0 < int(length) <= 2048):
                self.send_error(403)
                return
            if len(self.server.records) >= 2 or self.server.failure is not None:
                self.send_error(409)
                return
            try:
                verify()
                value = json.loads(self.rfile.read(int(length)))
                original = self.server.records[0]['snapshot'] if self.server.records else None
                validate_snapshot(value, original)
                if value['pid'] != pid:
                    raise ValueError('Observation process differs from owner')
                received = clock()
                if original is not None:
                    interval = received - self.server.records[0]['receivedMonotonic']
                    document_interval = (value['documentElapsed'] - original['documentElapsed']) / 1000
                    if not 3 <= interval <= 20 or abs(interval - document_interval) > 2:
                        raise ValueError('Receiver observation interval did not match')
                verify()
                self.server.records.append({'receivedMonotonic': received, 'snapshot': value})
            except (OSError, ValueError, subprocess.SubprocessError):
                # Never copy malformed bodies, tokens, URLs or exception text to results.
                self.server.failure = 'observation_rejected'
                self.send_error(409)
                return
            data = b'{"success":true,"memorySamplesTaken":0,"readyForRAM":false}'
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    class Server(http.server.HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(2)
            return connection, address

    server = Server(('127.0.0.1', 0), Handler)
    server.timeout = .5
    server.token = token
    server.records = []
    server.failure = None
    return server


def serve(workload_path):
    record = json.loads(workload_path.read_text())
    guard.validate(record)
    guard.validate_lifetime(record, 300)
    if record.get('dryRunPublicHandoff') is not True:
        raise ValueError('Requires the fixed explicit dry handoff workload')
    app = Path(record['executable']).parents[2]
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    revision = info.get('LevisticaSourceRevision')
    def verify():
        guard.verify_owned(record)
        checkout = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, timeout=3).strip()
        dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'],
                                        cwd=ROOT, text=True, timeout=3).strip()
        current = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if (dirty or checkout != revision or current.get('LevisticaSourceRevision') != revision
                or info.get('LevisticaSourceState') != 'clean' or current.get('LevisticaSourceState') != 'clean'):
            raise ValueError('Measurement source identity changed')
    verify()
    server = create_server(record['pid'], verify)
    output = workload_path.parent
    config = {'url': f'http://127.0.0.1:{server.server_port}/public-readiness', 'token': server.token,
              'pid': record['pid'], 'sourceRevision': revision}
    temporary = output / 'public-handoff.partial'
    temporary.write_text(json.dumps(config) + '\n')
    temporary.chmod(0o600)
    temporary.replace(output / 'public-handoff.json')
    deadline = time.monotonic() + 300
    try:
        while len(server.records) < 2 and server.failure is None and time.monotonic() < deadline:
            verify()
            server.handle_request()
        if len(server.records) != 2 and server.failure is None:
            server.failure = 'handoff_deadline_expired'
    except (OSError, ValueError, subprocess.SubprocessError):
        server.failure = 'owner_or_source_changed'
    finally:
        server.server_close()
        result = {'success': len(server.records) == 2 and server.failure is None,
                  'records': server.records, 'failure': server.failure, 'sourceRevision': revision,
                  'memorySamplesTaken': 0, 'readyForRAM': False}
        path = output / 'public-handoff-result.json'
        path.write_text(json.dumps(result, indent=2) + '\n')
        path.chmod(0o600)
    if not result['success']:
        raise ValueError('Live handoff did not complete')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workload', type=Path)
    serve(parser.parse_args().workload)
