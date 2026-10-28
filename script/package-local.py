#!/usr/bin/env python3
"""Package one verified local archive; never launch, install, sign or publish."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'script' / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


bundles = module('package_bundle_checks', 'rehearse-update.py')
security = module('package_security_checks', 'check-release-security.py')


def validate_zip(path):
    """Check all names before ditto sees them, including implicit directories."""
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if not entries or len(entries) > 4002 or sum(x.file_size for x in entries) > 512 * 1024**2:
            raise ValueError('Package exceeds entry or expanded-byte limits')
        explicit, components = set(), {}
        has_executable = False
        for entry in entries:
            name = entry.filename
            if (entry.orig_filename != name or '\\' in name or ':' in name
                    or any(ord(c) < 32 or ord(c) == 127 for c in name)):
                raise ValueError('Invalid archive member name')
            parts = name.removesuffix('/').split('/')
            if any(p in ('', '.', '..') for p in parts):
                raise ValueError('Archive paths must be relative and canonical')
            if parts[0] == '__MACOSX':
                # ditto's AppleDouble metadata may describe only the sealed app.
                if (len(parts) > 1 and parts[1] not in ('Levistica.app', '._Levistica.app')):
                    raise ValueError('Unexpected metadata root')
                if not entry.is_dir() and not parts[-1].startswith('._'):
                    raise ValueError('Unexpected metadata payload')
            elif parts[0] != 'Levistica.app':
                raise ValueError('Only the application may be packaged')
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR) or (mode & 0o7000):
                raise ValueError('Linked, special or privileged archive entries are not accepted')
            if (kind == stat.S_IFDIR and not entry.is_dir()) or (kind == stat.S_IFREG and entry.is_dir()):
                raise ValueError('Archive member type mismatch')
            canonical = '/'.join(parts)
            if canonical in explicit:
                raise ValueError('Duplicate archive member')
            explicit.add(canonical)
            for i in range(1, len(parts) + 1):
                actual = tuple(parts[:i])
                key = tuple(unicodedata.normalize('NFC', p).casefold() for p in actual)
                directory = i < len(parts) or entry.is_dir()
                previous = components.get(key)
                if previous is not None and previous != (actual, directory):
                    raise ValueError('Ambiguous case, Unicode or file/directory path')
                components[key] = (actual, directory)
            has_executable |= canonical == 'Levistica.app/Contents/MacOS/Levistica' and not entry.is_dir()
        if not has_executable or archive.testzip() is not None:
            raise ValueError('Missing executable or invalid ZIP checksum')


def write_json(path, data):
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        json.dump(data, file, indent=2)
        file.write('\n')


def package(archive):
    if sys.platform != 'darwin':
        raise ValueError('Local packaging requires macOS')
    archive = bundles.within_project(archive)
    parts = archive.relative_to(ROOT / '.local/archives').parts
    if (len(parts) != 2 or not re.fullmatch(r'local-[A-Za-z0-9]{6,32}', parts[0])
            or parts[1] != 'Levistica.xcarchive'):
        raise ValueError('Use an archive from the formal build entrypoint')
    app = archive / 'Products/Applications/Levistica.app'
    deadline = time.monotonic() + 120
    digest = bundles.tree_digest(app, deadline)
    # Current app has no embedded frameworks; reject links instead of extracting
    # link graphs. Future packaging changes must review this explicit boundary.
    for path in [app, *app.rglob('*')]:
        value = path.lstat()
        if path.is_symlink() or (stat.S_ISREG(value.st_mode) and value.st_nlink != 1) or value.st_mode & 0o7000:
            raise ValueError('Bundle links or privileged entries are not accepted')
    facts = security.check(app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = info.get('CFBundleShortVersionString', '')
    if not isinstance(version, str) or len(version) > 32 or re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version) is None:
        raise ValueError('Invalid package version')
    parent = bundles.within_project(ROOT / '.local/packages')
    parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='local-', dir=parent))
    work.chmod(0o700)
    print('Private package directory: ' + str(work), flush=True)
    phase = 'create'
    try:
        def run(command):
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError('Package deadline exceeded')
            subprocess.run(command, check=True, capture_output=True, timeout=min(30, left))
        partial = work / 'application.partial.zip'
        # Preserve the platform's normal resource/quarantine handling. Do not
        # remove trust attributes, re-sign, or alter the original archive.
        run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(partial)])
        partial.chmod(0o600)
        phase = 'validate_zip'
        validate_zip(partial)
        phase = 'extract'
        extracted = work / 'unpacked'
        extracted.mkdir(mode=0o700)
        run(['/usr/bin/ditto', '-x', '-k', str(partial), str(extracted)])
        if {p.name for p in extracted.iterdir()} != {'Levistica.app'}:
            raise ValueError('Unexpected extracted roots')
        unpacked = extracted / 'Levistica.app'
        phase = 'verify_roundtrip'
        if bundles.tree_digest(unpacked, deadline) != digest or bundles.tree_digest(app, deadline) != digest:
            raise ValueError('Package roundtrip or original bundle changed')
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(unpacked)])
        checksum_state = hashlib.sha256()
        with partial.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                if time.monotonic() > deadline:
                    raise TimeoutError('Package deadline exceeded')
                checksum_state.update(chunk)
        checksum = checksum_state.hexdigest()
        name = f'Levistica-{version}-local-{facts["source"][:7]}.zip'
        output = work / name
        # Exclusive publication: even an unexpected same-name file is retained.
        os.link(partial, output)
        partial.unlink()
        result = {'success': True, 'scope': 'local-validation', 'version': version,
                  'source': facts['source'], 'zipFile': name, 'zipSHA256': checksum,
                  'bundleTreeSHA256': digest, 'roundtripVerified': True, 'signatureVerified': True,
                  'sandbox': facts['sandbox'], 'hardenedRuntime': facts['hardenedRuntime'],
                  'adHocSignature': facts['adHocSignature'], 'notarizationVerified': False,
                  'appLaunched': False, 'appInstalled': False, 'published': False,
                  'normalDataUsed': False,
                  'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        write_json(work / 'manifest.json', result)
        print('Local package: ' + str(output), flush=True)
        return result
    except (Exception, KeyboardInterrupt) as error:
        write_json(work / 'failure.json', {'success': False, 'phase': phase, 'errorType': type(error).__name__,
                                         'appLaunched': False, 'appInstalled': False, 'published': False})
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    args = parser.parse_args()
    try:
        package(args.archive)
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException, subprocess.SubprocessError):
        print('Local packaging could not be verified; no launch, install or publication was performed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
