#!/usr/bin/env python3
"""Prepare and validate the opt-in five-document Profile XCTest workload."""
import argparse
import importlib.util
import json
import os
import pathlib
import http.server
import secrets
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('app_processes', ROOT / 'script/check-app-processes.py')
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)


def validate_state(state, completed=False):
    if (state.get('kind') != 'sleep-documents' or state.get('expected_tabs') != 5
            or state.get('transport') != 'same-origin-sse-lifecycle-v1'
            or state.get('invalid_reason')):
        raise ValueError('Not a valid five-document lifecycle fixture')
    expected = {str(n): 3 if completed and n < 5 else 1 if completed else 0 for n in range(1, 6)}
    if state.get('loads') != sum(expected.values()) or state.get('document_loads') != expected:
        raise ValueError('Unexpected document load counts; do not retry the workload automatically')
    if completed:
        documents = state.get('documents', {})
        if set(documents) != set(expected) or not all(
                d.get('complete') and d.get('seenVisible') and d.get('sections') == 240
                for d in documents.values()):
            raise ValueError('Some documents did not report readiness')
    return expected



def validate_snapshots(directory, pressure_relief=False):
    files = []
    stages = RELIEF_STAGES if pressure_relief else STAGES
    for stage in stages:
        for tool in ('vmmap',) if pressure_relief else ('vmmap', 'malloc_history'):
            path = directory / f'{stage}-{tool}.txt'
            size = path.stat().st_size
            if not 0 < size <= 8 * 1024 * 1024:
                raise ValueError('Missing, empty, or oversized diagnostic snapshot')
            files.append({'name': path.name, 'bytes': size})
    return files



STAGES = ('loaded-five', 'sleep-1', 'sleep-2', 'resumed-two')
RELIEF_STAGES = ('loaded-five', 'sleep-1', 'sleep-2', 'after-relief')
MAX_BYTES = 8 * 1024 * 1024


def capture_tool(directory, stage, tool, arguments):
    output = directory / f'{stage}-{tool}.txt'
    started = time.monotonic()
    with output.open('xb') as stream:
        output.chmod(0o600)
        process = subprocess.Popen(['/usr/bin/' + tool, *arguments], stdout=stream, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                if time.monotonic() - started > 10 or output.stat().st_size > MAX_BYTES:
                    raise TimeoutError('Diagnostic command exceeded its time or output cap')
                time.sleep(0.05)
            if process.returncode != 0:
                raise ValueError(f'Diagnostic command failed: {tool}, exit {process.returncode}')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    size = output.stat().st_size
    if not 0 < size <= MAX_BYTES:
        raise ValueError('Empty or oversized diagnostic command output')
    return {'name': output.name, 'bytes': size, 'seconds': time.monotonic() - started}


def request_is_valid(headers, host, token):
    supplied = headers.get('X-Levistica-Diagnostic', '')
    return (isinstance(supplied, str) and supplied.isascii()
            and headers.get('Host') == host and headers.get('Origin') is None
            and headers.get('Content-Length') in (None, '0')
            and headers.get('Transfer-Encoding') is None
            and secrets.compare_digest(supplied, token))


def create_collector(pid, verify, capture, pressure_relief=False):
    stages = RELIEF_STAGES if pressure_relief else STAGES
    token = secrets.token_urlsafe(32)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            if not request_is_valid(self.headers, f'127.0.0.1:{self.server.server_port}', token):
                self.send_error(403)
                return
            index = len(self.server.records)
            if index >= len(stages) or self.path != '/snapshot/' + stages[index]:
                self.send_error(409)
                return
            stage = stages[index]
            try:
                results = []
                tools = [('vmmap', ['-summary', str(pid)])]
                if not pressure_relief:
                    tools.append(('malloc_history', [str(pid), '-callTree', '.*[8m+]']))
                for tool, arguments in tools:
                    verify()
                    results.append(capture(stage, tool, arguments))
                    verify()
                self.server.records.append({'stage': stage, 'samples': results})
                success = True
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                self.server.failure = str(error)
                success = False
            data = json.dumps({'success': success}).encode()
            self.send_response(200 if success else 500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    class Collector(http.server.HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(5)
            return connection, address

    server = Collector(('127.0.0.1', 0), Handler)
    server.timeout = 1
    server.records = []
    server.failure = None
    server.token = token
    return server


def serve_collector(workload_path):
    workload = json.loads(workload_path.read_text())
    relief = workload.get('allocatorRelief', False)
    if bool(workload.get('mallocStacks')) == bool(relief):
        raise ValueError('Collector requires exactly one diagnostic mode')
    pid = workload['pid']
    birth = processes.run_ps(['-p', str(pid), '-o', 'lstart='])
    if birth is None:
        raise ValueError('Profile process exited before collector startup')

    def verify():
        snapshot = processes.run_ps(['-axo', 'pid=,comm='])
        if snapshot is None:
            raise ValueError('Cannot enumerate app processes')
        pids = processes.check_snapshot(snapshot, ROOT, processes.describe_process, os.getuid(), only='Profile')
        if pids != [pid] or processes.run_ps(['-p', str(pid), '-o', 'lstart=']) != birth:
            raise ValueError('Profile PID or start time changed')

    verify()
    directory = workload_path.parent
    server = create_collector(pid, verify, lambda stage, tool, args: capture_tool(directory, stage, tool, args), pressure_relief=relief)
    workload['collector'] = {'url': f'http://127.0.0.1:{server.server_port}', 'token': server.token}
    temporary = workload_path.with_suffix('.tmp')
    temporary.write_text(json.dumps(workload, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(workload_path)
    (directory / 'collector-ready.json').write_text('{"ready":true}\n')
    deadline = time.monotonic() + 180
    try:
        while len(server.records) < len(STAGES) and server.failure is None and time.monotonic() < deadline:
            server.handle_request()
        if len(server.records) != len(STAGES) and server.failure is None:
            server.failure = 'Collector deadline expired'
    finally:
        server.server_close()
        (directory / 'collector-result.json').write_text(json.dumps(
            {'records': server.records, 'failure': server.failure}, indent=2) + '\n')
    if server.failure:
        raise ValueError(server.failure)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'validate', 'serve'])
    parser.add_argument('state', type=pathlib.Path)
    parser.add_argument('output', nargs='?', type=pathlib.Path)
    args = parser.parse_args()
    if args.mode == 'serve':
        if args.output is None:
            parser.error('serve requires the workload file')
        serve_collector(args.output)
        return
    state = json.loads(args.state.read_text())
    counts = validate_state(state, completed=args.mode == 'validate')
    if args.mode == 'prepare':
        if args.output is None:
            parser.error('prepare requires an output file')
        snapshot = processes.run_ps(['-axo', 'pid=,comm='])
        if snapshot is None:
            raise ValueError('Process enumeration failed')
        pids = processes.check_snapshot(snapshot, ROOT, processes.describe_process, os.getuid(), only='Profile')
        if len(pids) != 1:
            raise ValueError('Exactly one verified Profile process is required')
        args.output.write_text(json.dumps({'pid': pids[0], 'executable': next(path for path, identifier in processes.known_apps(ROOT).items() if identifier.endswith('.profile')), 'urls': state['urls'], 'mallocStacks': os.environ.get('LEVISTICA_MALLOC_STACKS', '0') == '1', 'allocatorRelief': os.environ.get('LEVISTICA_ALLOCATOR_RELIEF', '0') == '1'}, indent=2) + '\n')
        args.output.chmod(0o600)
        print('Profile workload prepared for one verified process.')
    else:
        workload = json.loads(args.state.with_name('workload.json').read_text())
        snapshots = validate_snapshots(args.state.parent, pressure_relief=workload.get('allocatorRelief', False)) if workload.get('mallocStacks') or workload.get('allocatorRelief') else []
        print(json.dumps({'snapshots': snapshots, 'completed': True, 'cycles': 2, 'sleeps': 8, 'resumes': 8,
                          'loads': sum(counts.values()), 'document_loads': counts}))


if __name__ == '__main__':
    main()
